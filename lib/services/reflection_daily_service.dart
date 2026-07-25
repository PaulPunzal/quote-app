import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'reflection_embedding_service.dart';
import '../models/embedded_reflection.dart';

/// Which "moment" a reflection is being picked for.
///
/// - [morning] / [evening]: ambient, auto-picked from weather + time only
///   (no mood check-in). Fixed once assigned for the day.
/// - [onDemand]: the "how are you, right now?" pick, driven by the mood
///   check-in. Callers can pass `forceReroll: true` for a fresh pick.
enum ReflectionSlot { morning, evening, onDemand }

extension ReflectionSlotKey on ReflectionSlot {
  String get storageKey => switch (this) {
        ReflectionSlot.morning => 'morning',
        ReflectionSlot.evening => 'evening',
        ReflectionSlot.onDemand => 'ondemand',
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

/// Picks and persists reflections for up to three daily "slots" --
/// morning, evening, and an on-demand mood-driven pick.
///
/// MATCHING STRATEGY: a diagnostic against the real embedded corpus
/// showed only ~10% of reflections were EVER reachable as a
/// Morning/Evening headline under top-N nearest-neighbor matching --
/// most reflections are universal/timeless text with no real semantic
/// relationship to weather or time-of-day, so "best match" always
/// picked from the same narrow ~30-reflection slice regardless of
/// actual conditions. That slice was the loop.
///
/// So each slot now:
///   1. Ranks the full corpus against its context vector.
///   2. Excludes only the worst-scoring tail (`exclusionFraction`) as
///      "clearly wrong for this moment" -- a coarse sanity filter,
///      not a precision picker.
///   3. Picks uniformly at random from what's left, after hard
///      exclusion, flexible recency exclusion, and (for headline
///      slots) rotation exclusion.
///
/// Weather/time/mood still matter -- a stormy-day reflection is still
/// less likely to appear on a clear day -- but the large majority of
/// "timeless" content can now actually rotate through, which top-N
/// never allowed.
///
/// TWO LAYERS OF ANTI-REPEAT, PER SLOT:
///
///   1. HARD EXCLUDE (`hardExcludeCount`): the last few reflections
///      shown for THIS SPECIFIC SLOT are always excluded from that
///      slot's next pick, no matter what -- this exclusion is unioned
///      in at EVERY fallback branch below and never relaxed away. This
///      is what actually guarantees no immediate/short-cycle repeat,
///      even under pressure (e.g. many "Something else" taps in a
///      row, or a headline rotation cycle resetting).
///
///   2. FLEXIBLE RECENCY (`recencyWindowDays` / rotation): a wider,
///      "don't show this too often" layer that IS allowed to relax
///      when the eligible pool gets too small. Its job is variety
///      over the medium/long term, not the no-repeat guarantee --
///      that guarantee lives entirely in layer 1.
///
/// HEADLINE ROTATION (replaces the old time-based cooldown): instead
/// of barring a headline for N days and hoping that's long enough, we
/// track the full set of reflection ids that have "had their turn" as
/// a Morning/Evening headline (or been actually READ -- not merely
/// offered -- in Explore's "similar to this headline" band). That
/// used-set is excluded from headline candidates until every
/// reachable reflection for the current context has had a turn, at
/// which point the set resets and a new cycle begins. This guarantees
/// no headline can repeat until the rest of the reachable corpus has
/// been shown at least once, rather than relying on a fixed number of
/// days being "probably enough."
class ReflectionDailyService {
  static const _keyAssignedReflections = 'assigned_reflections_v2';
  static const _keyHistory = 'reflection_shown_history';
  static const _keyHeadlineRotationUsed = 'headline_rotation_used_ids';

  final ReflectionEmbeddingService _embeddingService;

  /// Starting size of the flexible recency window for headline slots
  /// (days). Can shrink under pressure -- see `_rankEligibleHeadlinePool`.
  final int recencyWindowDays;

  /// Starting size of the flexible recency window for the on-demand
  /// slot (days). Kept separate from [recencyWindowDays] and slightly
  /// longer, since on-demand has no rotation layer behind it -- this
  /// is its main defense against medium-term repetition.
  final int onDemandRecencyWindowDays;

  /// Non-negotiable: the last [hardExcludeCount] reflections shown for
  /// a given slot are ALWAYS excluded from that slot's next pick, no
  /// matter how much the flexible recency window has to relax under
  /// pressure. This is what actually guarantees no back-to-back
  /// repeat -- the flexible window's job is variety, not the
  /// no-repeat guarantee, since it's allowed to shrink to nothing when
  /// the eligible pool gets tight.
  final int hardExcludeCount;

  /// Floor below which exclusion/recency gets relaxed rather than
  /// leaving a near-empty pool to pick from.
  final int minCandidateFloor;

  /// Fraction of the ranked corpus excluded as "worst match" before
  /// picking randomly from the rest. 0.25 for headlines: the bottom
  /// quarter (least weather/time-relevant) is excluded, the top
  /// three-quarters are all fair game -- deliberately loose, since
  /// most of this corpus is timeless and shouldn't be gatekept by a
  /// weak time/weather signal.
  final double headlineExclusionFraction;

  /// Tighter than headlines: mood (weighted to dominate below) is a
  /// more meaningful signal than weather/time turned out to be, so
  /// it's worth trusting a bit more.
  final double onDemandExclusionFraction;

  final Random _random;

  ReflectionDailyService({
    ReflectionEmbeddingService? embeddingService,
    this.recencyWindowDays = 14,
    this.onDemandRecencyWindowDays = 21,
    this.hardExcludeCount = 3,
    this.minCandidateFloor = 15,
    this.headlineExclusionFraction = 0.25,
    this.onDemandExclusionFraction = 0.20,
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
    final isHeadlineSlot =
        slot == ReflectionSlot.morning || slot == ReflectionSlot.evening;

    final contextVector = isHeadlineSlot
        ? await _embeddingService.buildContextVector(
            weatherId: weatherId,
            timeId: resolvedTimeId,
          )
        : await _embeddingService.buildContextVector(
            moodId: moodId,
            weatherId: weatherId,
            timeId: resolvedTimeId,
            // Mood dominates the on-demand pick -- it's the whole
            // point of "how are you, right now?". Headline slots
            // already own weather/time as their primary signal.
            moodWeight: 2.0,
            weatherWeight: 0.4,
            timeWeight: 0.6,
          );

    final hardExclude = await _hardExcludeIds(prefs, slot);

    final eligible = isHeadlineSlot
        ? await _rankEligibleHeadlinePool(prefs, contextVector, hardExclude)
        : await _rankEligibleOnDemandPool(prefs, contextVector, hardExclude);

    final picked = eligible[_random.nextInt(eligible.length)].reflection;

    todaysSlots[slot.storageKey] = picked.id;
    assignedMap[today] = todaysSlots;
    await _saveAssignedMap(prefs, assignedMap);
    await _appendToHistory(prefs, picked.id, today, slot.storageKey);

    if (isHeadlineSlot) {
      await _markHeadlineRotationUsed(prefs, picked.id);
    }

    return picked;
  }

  /// The last [hardExcludeCount] ids shown for THIS specific slot
  /// (morning/evening/onDemand tracked separately, since they're
  /// independent contexts) -- read straight from history, newest
  /// first. Always honored, never relaxed, at every fallback tier in
  /// both `_rankEligibleHeadlinePool` and `_rankEligibleOnDemandPool`.
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

  /// Headline (Morning/Evening) pool. Three tiers, [hardExclude]
  /// unioned in at every single one so it's never dropped:
  ///   1. Honor recency + rotation + hard-exclude together.
  ///   2. If that's empty, drop the flexible recency window --
  ///      rotation + hard-exclude is the guarantee that actually
  ///      matters, recency is just a nice-to-have on top.
  ///   3. If STILL empty, the whole reachable corpus for this context
  ///      has had its turn this cycle -- reset rotation and start a
  ///      fresh cycle from the full corpus, but hard-exclude still
  ///      stands so the literal thing just shown can't immediately
  ///      reappear. (This is also what eventually surfaces the
  ///      handful of reflections that never rank in anyone's top
  ///      fraction on their own merits: once everything else is
  ///      excluded, they're what's left.)
  Future<List<ScoredReflection>> _rankEligibleHeadlinePool(
    SharedPreferences prefs,
    List<double> contextVector,
    Set<String> hardExclude,
  ) async {
    var rotationUsed = await _getRotationUsed(prefs);
    final recentIds = await _recentlyShownIds(prefs, windowDays: recencyWindowDays);

    var ranked = await _embeddingService.rank(
      contextVector,
      excludeIds: {...recentIds, ...rotationUsed, ...hardExclude},
    );
    var pool = _topFraction(ranked, headlineExclusionFraction);
    if (pool.isNotEmpty) return pool;

    ranked = await _embeddingService.rank(
      contextVector,
      excludeIds: {...rotationUsed, ...hardExclude},
    );
    pool = _topFraction(ranked, headlineExclusionFraction);
    if (pool.isNotEmpty) return pool;

    // Full cycle exhausted for this context -- everyone's had a turn.
    // Reset rotation; hard-exclude still stands.
    rotationUsed = {};
    await _saveRotationUsed(prefs, rotationUsed);
    ranked = await _embeddingService.rank(contextVector, excludeIds: hardExclude);
    pool = _topFraction(ranked, headlineExclusionFraction);
    if (pool.isNotEmpty) return pool;

    // Last resort (corpus smaller than hardExcludeCount+1 -- shouldn't
    // happen at 300 reflections, but never return an empty list): drop
    // even hard-exclude rather than crash on eligible[random.nextInt(0)].
    ranked = await _embeddingService.rank(contextVector);
    return _topFraction(ranked, headlineExclusionFraction);
  }

  /// On-demand pool: flexible recency window that can relax under
  /// pressure (e.g. many "Something else" taps in a row), but
  /// [hardExclude] is unioned in at EVERY step regardless -- so even
  /// once the flexible window relaxes all the way to nothing, the
  /// last few on-demand picks still can't repeat back-to-back.
  Future<List<ScoredReflection>> _rankEligibleOnDemandPool(
    SharedPreferences prefs,
    List<double> contextVector,
    Set<String> hardExclude,
  ) async {
    var window = onDemandRecencyWindowDays;

    while (true) {
      final recentIds = await _recentlyShownIds(prefs, windowDays: window);
      final ranked = await _embeddingService.rank(
        contextVector,
        excludeIds: {...recentIds, ...hardExclude},
      );
      final eligible = _topFraction(ranked, onDemandExclusionFraction);

      if (eligible.length >= minCandidateFloor || window <= 0) {
        if (eligible.isNotEmpty) return eligible;
        // Last resort, mirrors the headline path above: never return
        // an empty list, even if that means dropping hard-exclude in
        // the pathological case of a near-empty corpus.
        final fallbackRanked = await _embeddingService.rank(contextVector);
        return _topFraction(fallbackRanked, onDemandExclusionFraction);
      }
      window = window ~/ 2;
    }
  }

  /// Keeps the top (1 - [exclusionFraction]) of [ranked], but never
  /// fewer than [minCandidateFloor] (or the whole list, if smaller).
  List<ScoredReflection> _topFraction(
    List<ScoredReflection> ranked,
    double exclusionFraction,
  ) {
    if (ranked.isEmpty) return ranked;
    final byFraction = (ranked.length * (1 - exclusionFraction)).ceil();
    final count = max(byFraction, min(minCandidateFloor, ranked.length));
    return ranked.take(count).toList();
  }

  // ---------------------------------------------------------------------
  // Headline rotation (replaces the old day-based cooldown)
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
  /// had its headline turn when it's actually READ (not merely
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