import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'reflection_embedding_service.dart';
import '../models/embedded_reflection.dart';

/// Which daily "slot" a reflection is being picked for.
///
/// Both slots are now picked with the exact same strategy (see
/// [ReflectionDailyService] class doc) — mood-dominant ranking when a
/// mood is supplied, uniform-random when it isn't. There is no longer
/// a structural difference between them; they're kept as two separate
/// enum values purely because each needs its own storage key, history,
/// hard-exclude, and recency tracking (decision: still two slots, not
/// one reflection per day).
enum ReflectionSlot { morning, evening }

extension ReflectionSlotKey on ReflectionSlot {
  String get storageKey => switch (this) {
        ReflectionSlot.morning => 'morning',
        ReflectionSlot.evening => 'evening',
      };
}

class DailyHeadline {
  final String date;
  final String? morningId;
  final String? eveningId;

  const DailyHeadline({
    required this.date,
    required this.morningId,
    required this.eveningId,
  });
}

/// Picks and persists reflections for the two daily slots -- morning
/// and evening.
///
/// PICK STRATEGY (unified across both slots as of this refactor):
///   - Mood supplied → rank the full corpus against a mood-dominant
///     context vector (`moodWeight: 2.0, weatherWeight: 0.4,
///     timeWeight: 0.6` -- previously exclusive to the old on-demand
///     slot), then pick uniformly at random from the top
///     `1 - exclusionFraction` of that ranking.
///   - Mood NOT supplied (explicit skip -- see MoodCheckInResult) →
///     skip ranking entirely and pick uniformly at random from the
///     full corpus. Anti-repeat rules (hard-exclude, recency,
///     rotation) still apply exactly the same either way -- "random"
///     only means "skip the similarity step," never "skip the
///     exclusion rules."
///
/// Previously, Morning/Evening ("headline") picks used weather+time
/// only, while a separate on-demand slot used mood+weather+time --
/// two ranking methods to maintain for what was conceptually the same
/// operation. That's now one method, `_resolveEligiblePick`, used by
/// both slots and both the ranked and random paths.
///
/// TWO LAYERS OF ANTI-REPEAT, PER SLOT (unchanged from before):
///
///   1. HARD EXCLUDE (`hardExcludeCount`): the last few reflections
///      shown for THIS SPECIFIC SLOT are always excluded from that
///      slot's next pick, no matter what -- unioned in at every
///      fallback tier below and never relaxed away. This is the
///      actual no-repeat guarantee.
///
///   2. FLEXIBLE RECENCY (`recencyWindowDays`) + HEADLINE ROTATION
///      (`_keyHeadlineRotationUsed`): a wider "don't show this too
///      often" layer, shared across BOTH slots (a reflection shown as
///      Morning counts against Evening too), that IS allowed to relax
///      when the eligible pool gets too small. Its job is variety, not
///      the no-repeat guarantee -- that's entirely layer 1.
///
///      Rotation tracks every reflection that's "had its turn" in
///      either slot (or been actually READ -- not merely offered -- in
///      Explore's "similar to this headline" band). That used-set is
///      excluded from candidates until every reachable reflection for
///      the current context has had a turn, at which point it resets
///      and a new cycle begins.
///
///      This same tiered fallback (recency+rotation+hard-exclude →
///      rotation+hard-exclude → reset rotation, hard-exclude only →
///      hard-exclude dropped too as an absolute last resort) now
///      applies identically whether the pick is mood-ranked or random
///      -- see `_resolveEligiblePick`.
class ReflectionDailyService {
  static const _keyAssignedReflections = 'assigned_reflections_v2';
  static const _keyHistory = 'reflection_shown_history';
  static const _keyHeadlineRotationUsed = 'headline_rotation_used_ids';

  final ReflectionEmbeddingService _embeddingService;

  /// Flexible recency window (days), shared by both slots. Can shrink
  /// under pressure -- see `_resolveEligiblePick`'s tier cascade.
  final int recencyWindowDays;

  /// Non-negotiable: the last [hardExcludeCount] reflections shown for
  /// a given slot are ALWAYS excluded from that slot's next pick, no
  /// matter how much the flexible recency window has to relax under
  /// pressure.
  final int hardExcludeCount;

  /// Floor below which the ranked path's top-fraction cutoff gets
  /// relaxed rather than leaving a near-empty pool to pick from.
  final int minCandidateFloor;

  /// Fraction of the ranked corpus excluded as "worst match" before
  /// picking randomly from the rest, when a mood context vector is
  /// available. Only applies to the ranked path -- the random path
  /// (no mood given) has no scores to cut by, so it filters the whole
  /// corpus down by exclusion set alone. 0.20 mirrors the old
  /// on-demand-only value: now that every ranked pick is mood-driven,
  /// mood's signal is trusted the same way everywhere.
  final double exclusionFraction;

  final Random _random;

  ReflectionDailyService({
    ReflectionEmbeddingService? embeddingService,
    this.recencyWindowDays = 14,
    this.hardExcludeCount = 3,
    this.minCandidateFloor = 15,
    this.exclusionFraction = 0.20,
    Random? random,
  })  : _embeddingService = embeddingService ?? ReflectionEmbeddingService(),
        _random = random ?? Random();

  String _todayString() => _dateToString(DateTime.now());

  static String _dateToString(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  /// Maps the current hour into one of the four precomputed time
  /// buckets. Purely a lookup -- no model, no embedding happens here.
  static String timeBucketIdForHour(int hour) {
    if (hour >= 5 && hour < 11) return 'time_morning';
    if (hour >= 11 && hour < 17) return 'time_midday';
    if (hour >= 17 && hour < 22) return 'time_evening';
    return 'time_night';
  }

  // ---------------------------------------------------------------------
  // Core slot API
  // ---------------------------------------------------------------------

  /// Picks (or loads today's already-picked) reflection for [slot].
  ///
  /// [moodId] is optional -- omit it (or pass null) to take the random
  /// path described in the class doc, e.g. when the person tapped
  /// "I don't know" on the mood check-in (`MoodSkipped`). This is
  /// different from the caller not calling this method at all, which
  /// is the right response to `MoodCancelled` -- that case shouldn't
  /// reach this method in the first place.
  Future<EmbeddedReflection> getSlotReflection({
    required ReflectionSlot slot,
    String? moodId,
    String? weatherId,
    String? timeId,
    bool forceReroll = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayString();

    final assignedMap = await _getAssignedMap(prefs);
    final todaysSlots = Map<String, String>.from(assignedMap[today] ?? {});

    if (!forceReroll) {
      final existingId = todaysSlots[slot.storageKey];
      if (existingId != null) {
        final all = await _embeddingService.allReflections();
        final existing = all.where((r) => r.id == existingId);
        if (existing.isNotEmpty) return existing.first;
        // Stored id no longer exists -- fall through and pick fresh.
      }
    }

    final resolvedTimeId = timeId ?? timeBucketIdForHour(DateTime.now().hour);

    // Mood-ranked path builds a context vector; the random path (no
    // mood given) skips this entirely -- `_resolveEligiblePick` reads
    // contextVector == null as "don't rank, just filter and pick."
    final contextVector = moodId != null
        ? await _embeddingService.buildContextVector(
            moodId: moodId,
            weatherId: weatherId,
            timeId: resolvedTimeId,
            // Mood dominates -- this was previously exclusive to the
            // on-demand slot, now shared by both slots (decision 2).
            moodWeight: 2.0,
            weatherWeight: 0.4,
            timeWeight: 0.6,
          )
        : null;

    final hardExclude = await _hardExcludeIds(prefs, slot);
    final picked = await _resolveEligiblePick(
      prefs,
      contextVector: contextVector,
      hardExclude: hardExclude,
    );

    todaysSlots[slot.storageKey] = picked.id;
    assignedMap[today] = todaysSlots;
    await _saveAssignedMap(prefs, assignedMap);
    await _appendToHistory(prefs, picked.id, today, slot.storageKey);

    // Rotation bookkeeping applies to every pick now, ranked or
    // random -- both slots are "headline" slots (decision 5: kept,
    // shared across both).
    await _markHeadlineRotationUsed(prefs, picked.id);

    return picked;
  }

  /// The last [hardExcludeCount] ids shown for THIS specific slot
  /// (morning/evening tracked separately, since they're independent
  /// contexts) -- read straight from history, newest first. Always
  /// honored, never relaxed, at every tier in `_resolveEligiblePick`.
  Future<Set<String>> _hardExcludeIds(
    SharedPreferences prefs,
    ReflectionSlot slot,
  ) async {
    final history = await _getHistory(prefs);
    final slotHistory =
        history.where((e) => e['slot'] == slot.storageKey).toList();
    return slotHistory.reversed
        .take(hardExcludeCount)
        .map((e) => e['id']!)
        .toSet();
  }

  /// Shared pick resolution for both slots and both strategies
  /// (mood-ranked when [contextVector] is non-null, random when it's
  /// null). Replaces the old separate `_rankEligibleHeadlinePool` /
  /// `_rankEligibleOnDemandPool` methods (decision 2).
  ///
  /// Four tiers, [hardExclude] unioned in at every one so it's never
  /// silently dropped except at the very last resort:
  ///   1. Honor recency + rotation + hard-exclude together.
  ///   2. If that's empty, drop the flexible recency window --
  ///      rotation + hard-exclude is the guarantee that actually
  ///      matters, recency is just a nice-to-have on top.
  ///   3. If STILL empty, the whole reachable corpus for this context
  ///      has had its turn this cycle -- reset rotation and start a
  ///      fresh cycle, but hard-exclude still stands so the literal
  ///      thing just shown can't immediately reappear.
  ///   4. Last resort (corpus smaller than hardExcludeCount+1 --
  ///      shouldn't happen at normal corpus sizes): drop even
  ///      hard-exclude rather than leave nothing to pick from.
  Future<EmbeddedReflection> _resolveEligiblePick(
    SharedPreferences prefs, {
    required List<double>? contextVector,
    required Set<String> hardExclude,
  }) async {
    var rotationUsed = await _getRotationUsed(prefs);
    final recentIds =
        await _recentlyShownIds(prefs, windowDays: recencyWindowDays);

    var pool = await _candidatePool(
      contextVector,
      excludeIds: {...recentIds, ...rotationUsed, ...hardExclude},
    );
    if (pool.isNotEmpty) return _pickFrom(pool);

    pool = await _candidatePool(
      contextVector,
      excludeIds: {...rotationUsed, ...hardExclude},
    );
    if (pool.isNotEmpty) return _pickFrom(pool);

    // Full cycle exhausted for this context -- everyone's had a turn.
    // Reset rotation; hard-exclude still stands.
    rotationUsed = {};
    await _saveRotationUsed(prefs, rotationUsed);
    pool = await _candidatePool(contextVector, excludeIds: hardExclude);
    if (pool.isNotEmpty) return _pickFrom(pool);

    // Last resort: drop hard-exclude too rather than have nothing to
    // pick from.
    pool = await _candidatePool(contextVector, excludeIds: const {});
    return _pickFrom(pool);
  }

  /// Builds one tier's candidate list:
  ///   - [contextVector] non-null → rank the corpus against it, keep
  ///     the top [exclusionFraction]-adjusted slice (via
  ///     `_topFraction`), excluding [excludeIds].
  ///   - [contextVector] null → the random path: just the corpus minus
  ///     [excludeIds], no ranking or scoring at all.
  Future<List<EmbeddedReflection>> _candidatePool(
    List<double>? contextVector, {
    required Set<String> excludeIds,
  }) async {
    if (contextVector == null) {
      final all = await _embeddingService.allReflections();
      return all.where((r) => !excludeIds.contains(r.id)).toList();
    }

    final ranked = await _embeddingService.rank(
      contextVector,
      excludeIds: excludeIds,
    );
    return _topFraction(ranked, exclusionFraction)
        .map((s) => s.reflection)
        .toList();
  }

  EmbeddedReflection _pickFrom(List<EmbeddedReflection> pool) {
    return pool[_random.nextInt(pool.length)];
  }

  /// Keeps the top (1 - [exclusionFraction]) of [ranked], but never
  /// fewer than [minCandidateFloor] (or the whole list, if smaller).
  List<ScoredReflection> _topFraction(
    List<ScoredReflection> ranked,
    double fraction,
  ) {
    if (ranked.isEmpty) return ranked;
    final byFraction = (ranked.length * (1 - fraction)).ceil();
    final count = max(byFraction, min(minCandidateFloor, ranked.length));
    return ranked.take(count).toList();
  }

  // ---------------------------------------------------------------------
  // Headline rotation (shared across both slots -- decision 5, unchanged
  // mechanism from before this refactor)
  // ---------------------------------------------------------------------

  Future<Set<String>> _getRotationUsed(SharedPreferences prefs) async {
    return (prefs.getStringList(_keyHeadlineRotationUsed) ?? const []).toSet();
  }

  Future<void> _saveRotationUsed(
    SharedPreferences prefs,
    Set<String> ids,
  ) async {
    await prefs.setStringList(_keyHeadlineRotationUsed, ids.toList());
  }

  Future<void> _markHeadlineRotationUsed(
    SharedPreferences prefs,
    String id,
  ) async {
    final used = await _getRotationUsed(prefs);
    used.add(id);
    await _saveRotationUsed(prefs, used);
  }

  /// Public entry point for HomeScreen to mark a reflection as having
  /// had its rotation turn when it's actually READ (not merely
  /// offered) in Explore's "similar to this headline" band.
  Future<void> markHeadlineRotationUsed(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await _markHeadlineRotationUsed(prefs, id);
  }

  /// Public getter so Explore can exclude the whole current rotation
  /// cycle's used set from its "similar to this headline" band --
  /// not just today's two literal headlines -- so a reflection that's
  /// already had its turn this cycle can't even be offered there,
  /// let alone picked.
  Future<Set<String>> getHeadlineRotationUsedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return _getRotationUsed(prefs);
  }

  /// [moodId] omitted (or null) takes the random path -- see class doc
  /// and `getSlotReflection`.
  Future<EmbeddedReflection> rerollSlot({
    required ReflectionSlot slot,
    String? moodId,
    String? weatherId,
  }) {
    return getSlotReflection(
      slot: slot,
      moodId: moodId,
      weatherId: weatherId,
      forceReroll: true,
    );
  }

  Future<bool> hasSlotAssignment(ReflectionSlot slot) async {
    final prefs = await SharedPreferences.getInstance();
    final assignedMap = await _getAssignedMap(prefs);
    final todaysSlots = assignedMap[_todayString()];
    return todaysSlots != null && todaysSlots.containsKey(slot.storageKey);
  }

  Future<EmbeddedReflection?> getSlotIfAssigned(ReflectionSlot slot) async {
    final prefs = await SharedPreferences.getInstance();
    final assignedMap = await _getAssignedMap(prefs);
    final existingId = assignedMap[_todayString()]?[slot.storageKey];
    if (existingId == null) return null;

    final all = await _embeddingService.allReflections();
    final existing = all.where((r) => r.id == existingId);
    return existing.isNotEmpty ? existing.first : null;
  }

  /// Loads today's assignment for [slot] on an arbitrary [date] (format
  /// `yyyy-MM-dd`), not just today. Added for the pre-5am case
  /// (decision 6): showing "yesterday's already-picked Evening"
  /// requires reading a slot for a date other than today, which the
  /// existing [getSlotIfAssigned] can't do since it's hardcoded to
  /// `_todayString()`.
  Future<EmbeddedReflection?> getSlotForDate(
    ReflectionSlot slot,
    String date,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final assignedMap = await _getAssignedMap(prefs);
    final existingId = assignedMap[date]?[slot.storageKey];
    if (existingId == null) return null;

    final all = await _embeddingService.allReflections();
    final existing = all.where((r) => r.id == existingId);
    return existing.isNotEmpty ? existing.first : null;
  }

  Future<List<DailyHeadline>> getDailyHeadlines() async {
    final prefs = await SharedPreferences.getInstance();
    final assignedMap = await _getAssignedMap(prefs);

    final dates = assignedMap.keys.toList()..sort((a, b) => b.compareTo(a));

    return dates
        .map((date) {
          final slots = assignedMap[date] ?? const {};
          return DailyHeadline(
            date: date,
            morningId: slots[ReflectionSlot.morning.storageKey],
            eveningId: slots[ReflectionSlot.evening.storageKey],
          );
        })
        .where((h) => h.morningId != null || h.eveningId != null)
        .toList();
  }

  // ---------------------------------------------------------------------
  // Storage helpers
  // ---------------------------------------------------------------------

  Future<Map<String, Map<String, String>>> _getAssignedMap(
      SharedPreferences prefs) async {
    final raw = prefs.getString(_keyAssignedReflections);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map((date, slots) => MapEntry(
          date,
          (slots as Map<String, dynamic>)
              .map((slot, id) => MapEntry(slot, id as String)),
        ));
  }

  Future<void> _saveAssignedMap(
    SharedPreferences prefs,
    Map<String, Map<String, String>> map,
  ) async {
    await prefs.setString(_keyAssignedReflections, jsonEncode(map));
  }

  Future<List<Map<String, String>>> _getHistory(
      SharedPreferences prefs) async {
    final raw = prefs.getString(_keyHistory);
    if (raw == null) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => (e as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v.toString())))
        .toList();
  }

  Future<void> _appendToHistory(
    SharedPreferences prefs,
    String reflectionId,
    String date,
    String slot,
  ) async {
    final history = await _getHistory(prefs);
    history.add({'id': reflectionId, 'date': date, 'slot': slot});
    await prefs.setString(_keyHistory, jsonEncode(history));
  }

  Future<Set<String>> _recentlyShownIds(
    SharedPreferences prefs, {
    int? windowDays,
  }) async {
    final history = await _getHistory(prefs);
    final effectiveWindow = windowDays ?? recencyWindowDays;
    final cutoff = DateTime.now().subtract(Duration(days: effectiveWindow));

    final recent = <String>{};
    for (final entry in history) {
      final date = DateTime.tryParse(entry['date'] ?? '');
      if (date != null && date.isAfter(cutoff)) {
        recent.add(entry['id']!);
      }
    }
    return recent;
  }

  Future<List<Map<String, String>>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = await _getHistory(prefs);
    return history.reversed.toList();
  }
}