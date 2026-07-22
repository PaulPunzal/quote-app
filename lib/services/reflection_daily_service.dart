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
///   3. Picks uniformly at random from what's left, after recency
///      exclusion and (for headline slots) cooldown exclusion.
///
/// Weather/time/mood still matter -- a stormy-day reflection is still
/// less likely to appear on a clear day -- but the large majority of
/// "timeless" content can now actually rotate through, which top-N
/// never allowed.
class ReflectionDailyService {
  static const _keyAssignedReflections = 'assigned_reflections_v2';
  static const _keyHistory = 'reflection_shown_history';
  static const _keySimilarBandHistory = 'explore_similar_band_history';

  final ReflectionEmbeddingService _embeddingService;
  final int recencyWindowDays;

  /// How long a reflection is barred from headline duty after being
  /// shown as one, OR after being offered in Explore's "similar" band.
  /// Now mostly a safety net rather than the primary anti-repeat
  /// mechanism -- see class doc -- since the eligible pool is large
  /// enough that plain randomness does most of the work.
  final int headlineCooldownDays;
  final int exploreCooldownDays;

  /// Floor below which exclusion/cooldown gets relaxed rather than
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
    this.headlineCooldownDays = 30,
    this.exploreCooldownDays = 30,
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

    final cooldownIds =
        isHeadlineSlot ? await _headlineCooldownIds(prefs) : <String>{};
    final exclusionFraction =
        isHeadlineSlot ? headlineExclusionFraction : onDemandExclusionFraction;

    final eligible = await _rankEligiblePool(
      prefs,
      contextVector,
      cooldownIds: cooldownIds,
      exclusionFraction: exclusionFraction,
    );

    final picked = eligible[_random.nextInt(eligible.length)].reflection;

    todaysSlots[slot.storageKey] = picked.id;
    assignedMap[today] = todaysSlots;
    await _saveAssignedMap(prefs, assignedMap);
    await _appendToHistory(prefs, picked.id, today, slot.storageKey);

    return picked;
  }

  /// Ranks [contextVector] against the corpus, excluding recently-shown
  /// ids (progressively relaxed) and [cooldownIds], then keeps
  /// everything except the bottom [exclusionFraction] of what's left --
  /// a loose "not clearly wrong" filter rather than a "best match"
  /// filter. Drops [cooldownIds] entirely as a last resort only if
  /// even a fully-relaxed recency window isn't enough to clear
  /// [minCandidateFloor].
  Future<List<ScoredReflection>> _rankEligiblePool(
    SharedPreferences prefs,
    List<double> contextVector, {
    Set<String> cooldownIds = const {},
    required double exclusionFraction,
  }) async {
    var window = recencyWindowDays;

    while (true) {
      final recentIds = await _recentlyShownIds(prefs, windowDays: window);
      final ranked = await _embeddingService.rank(
        contextVector,
        excludeIds: {...recentIds, ...cooldownIds},
      );
      final eligible = _topFraction(ranked, exclusionFraction);

      if (eligible.length >= minCandidateFloor || window <= 0) {
        if (eligible.length >= minCandidateFloor || cooldownIds.isEmpty) {
          return eligible;
        }
        final fallbackRanked = await _embeddingService.rank(
          contextVector,
          excludeIds: recentIds,
        );
        return _topFraction(fallbackRanked, exclusionFraction);
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

  Future<Set<String>> _headlineCooldownIds(SharedPreferences prefs) async {
    final ids = <String>{};

    final history = await _getHistory(prefs);
    final headlineCutoff =
        DateTime.now().subtract(Duration(days: headlineCooldownDays));
    for (final entry in history) {
      final slot = entry['slot'];
      if (slot != ReflectionSlot.morning.storageKey &&
          slot != ReflectionSlot.evening.storageKey) {
        continue;
      }
      final date = DateTime.tryParse(entry['date'] ?? '');
      if (date != null && date.isAfter(headlineCutoff)) {
        ids.add(entry['id']!);
      }
    }

    final similarShown = await _getSimilarBandHistory(prefs);
    final exploreCutoff =
        DateTime.now().subtract(Duration(days: exploreCooldownDays));
    for (final entry in similarShown) {
      final date = DateTime.tryParse(entry['date'] ?? '');
      if (date != null && date.isAfter(exploreCutoff)) {
        ids.add(entry['id']!);
      }
    }

    return ids;
  }

  Future<List<Map<String, String>>> _getSimilarBandHistory(
      SharedPreferences prefs) async {
    final raw = prefs.getString(_keySimilarBandHistory);
    if (raw == null) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => (e as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v.toString())))
        .toList();
  }

  /// Records that [ids] were just offered as Explore's "similar to
  /// this headline" band. Called regardless of whether the user swipes
  /// to any of them -- being shown there and being picked both count
  /// as "seen" for headline cooldown purposes. Only called from the
  /// ambient (Morning/Evening) entry point into Explore.
  Future<void> recordSimilarBandShown(List<String> ids) async {
    if (ids.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final history = await _getSimilarBandHistory(prefs);
    final today = _todayString();
    for (final id in ids) {
      history.add({'id': id, 'date': today});
    }
    final cutoff = DateTime.now().subtract(
        Duration(days: max(headlineCooldownDays, exploreCooldownDays) + 7));
    final trimmed = history.where((entry) {
      final date = DateTime.tryParse(entry['date'] ?? '');
      return date == null || date.isAfter(cutoff);
    }).toList();
    await prefs.setString(_keySimilarBandHistory, jsonEncode(trimmed));
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