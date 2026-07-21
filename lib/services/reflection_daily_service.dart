import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'reflection_embedding_service.dart';
import '../models/embedded_reflection.dart';

/// Which "moment" a reflection is being picked for.
///
/// - [morning] / [evening]: ambient, auto-picked from weather + time only
///   (no mood check-in). Fixed once assigned for the day, same as the old
///   single-reflection behavior — reopening the app later just returns
///   the same one.
/// - [onDemand]: the "how are you, right now?" pick, driven by the mood
///   check-in. Also cached per day like the others, but callers can pass
///   `forceReroll: true` (see [ReflectionDailyService.getSlotReflection])
///   to get a fresh pick without waiting for tomorrow — this is what
///   solves the old "one reflection and then you're done for the day"
///   dead end.
enum ReflectionSlot { morning, evening, onDemand }

extension ReflectionSlotKey on ReflectionSlot {
  String get storageKey => switch (this) {
        ReflectionSlot.morning => 'morning',
        ReflectionSlot.evening => 'evening',
        ReflectionSlot.onDemand => 'ondemand',
      };
}

/// A single day's ambient "headline" picks -- Morning and/or Evening,
/// whichever have been assigned so far for that date. Deliberately
/// excludes the on-demand/check-in slot: that one can be rerolled
/// repeatedly in a single day via "Something else", so unlike the
/// ambient slots it doesn't represent one stable daily pick worth
/// calling a "headline". See [ReflectionDailyService.getDailyHeadlines].
class DailyHeadline {
  final String date; // yyyy-MM-dd
  final String? morningId;
  final String? eveningId;

  const DailyHeadline({
    required this.date,
    required this.morningId,
    required this.eveningId,
  });
}

/// Picks and persists reflections for up to three daily "slots" —
/// morning, evening, and an on-demand mood-driven pick — replacing the
/// old single "today's reflection" model.
///
/// Storage shape: `{"2026-07-21": {"morning": "r014", "evening": "r002"}}`
/// — one date entry holding a map of slot -> reflection id. This is a
/// new storage key (not a migration of the old flat `date -> id` map),
/// since this is early-stage personal data and a from-scratch start is
/// simpler and safer than writing one-time migration logic for a single
/// user's local data.
///
/// Picking mechanics: ranks all reflections against the current context
/// vector, excludes anything shown recently (see [_recentlyShownIds] and
/// the progressive-relaxation logic in [getSlotReflection]), then picks
/// randomly from the top [topPoolSize] of what's left.
class ReflectionDailyService {
  static const _keyAssignedReflections =
      'assigned_reflections_v2'; // date -> {slot -> reflectionId}
  static const _keyHistory =
      'reflection_shown_history'; // list of {id, date, slot}

  final ReflectionEmbeddingService _embeddingService;
  final int recencyWindowDays;
  final int topPoolSize;
  final Random _random;

  ReflectionDailyService({
    ReflectionEmbeddingService? embeddingService,
    this.recencyWindowDays = 14,
    // Wider than before (was 6). A pool this small got exhausted fast
    // whenever the same mood/weather/time context recurred (which
    // happens a lot -- moods and weather don't vary infinitely), so
    // repeats started showing up well before the recency window even
    // expired. A bigger pool means more genuinely-different picks
    // before anything has to repeat.
    this.topPoolSize = 20,
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
  /// buckets from context_options.json. Purely a lookup — no model,
  /// no embedding happens here.
  static String timeBucketIdForHour(int hour) {
    if (hour >= 5 && hour < 11) return 'time_morning';
    if (hour >= 11 && hour < 17) return 'time_midday';
    if (hour >= 17 && hour < 22) return 'time_evening';
    return 'time_night';
  }

  // ---------------------------------------------------------------------
  // Core slot API
  // ---------------------------------------------------------------------

  /// Returns the reflection for [slot], picking a new one only if this
  /// slot doesn't have one assigned yet today (or if [forceReroll] is
  /// true, which skips the cache and always picks fresh — this is what
  /// an on-demand "give me another" button should call).
  ///
  /// [moodId] and [weatherId] are both optional: pass a mood id for the
  /// on-demand slot (that's the whole point of that slot), and pass
  /// [weatherId] whenever you have a current reading, for any slot. The
  /// time bucket is always computed automatically and always included,
  /// so a context vector can always be built even with no mood/weather.
  ///
  /// [timeId] optionally pins the time-of-day context (e.g. always
  /// `'time_morning'` for the morning slot) instead of deriving it from
  /// the current clock — so a slot keeps its intended flavor no matter
  /// what time it's actually opened/picked at. Omit it to fall back to
  /// whatever bucket the current hour maps to (what the on-demand slot
  /// wants, since it's meant to reflect "right now").
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
        // Stored id no longer exists (reflections.json changed) — fall
        // through and pick a fresh one below.
      }
    }

    final resolvedTimeId = timeId ?? timeBucketIdForHour(DateTime.now().hour);
    final contextVector = await _embeddingService.buildContextVector(
      moodId: moodId,
      weatherId: weatherId,
      timeId: resolvedTimeId,
    );

    final ranked = await _rankWithRelaxedRecency(prefs, contextVector);

    final poolSize = min(topPoolSize, ranked.length);
    final pool = ranked.take(poolSize).toList();
    final picked = pool[_random.nextInt(pool.length)].reflection;

    todaysSlots[slot.storageKey] = picked.id;
    assignedMap[today] = todaysSlots;
    await _saveAssignedMap(prefs, assignedMap);
    await _appendToHistory(prefs, picked.id, today, slot.storageKey);

    return picked;
  }

  /// Ranks [contextVector] against reflections, excluding recently-shown
  /// ones -- but instead of an all-or-nothing cutoff (full recency
  /// window, or none at all), progressively shrinks the recency window
  /// until there are enough non-recent candidates to fill [topPoolSize].
  ///
  /// The old behavior dropped recency exclusion entirely the moment the
  /// full window's candidates ran dry, which could hand back something
  /// shown minutes ago. Shrinking the window in steps means the *most*
  /// recently shown reflections stay excluded for as long as possible,
  /// and only the least-recently-excluded ones get let back in first.
  Future<List<ScoredReflection>> _rankWithRelaxedRecency(
    SharedPreferences prefs,
    List<double> contextVector,
  ) async {
    var window = recencyWindowDays;

    while (true) {
      final recentIds = await _recentlyShownIds(prefs, windowDays: window);
      final ranked = await _embeddingService.rank(
        contextVector,
        excludeIds: recentIds,
      );

      if (ranked.length >= topPoolSize || window <= 0) {
        return ranked;
      }

      // Not enough fresh candidates yet -- shrink the window (halving,
      // floor at 0) and try again before giving up recency exclusion
      // altogether.
      window = window ~/ 2;
    }
  }

  /// Convenience for a reroll: always picks fresh for [slot], ignoring
  /// (and then overwriting) whatever was cached for it today. Intended
  /// for the on-demand slot's "something else" action, but works for
  /// any slot if you want that elsewhere.
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

  /// True if [slot] already has a reflection assigned today. Lets the
  /// UI skip asking for mood/weather again and just fetch the cached
  /// pick via [getSlotIfAssigned].
  Future<bool> hasSlotAssignment(ReflectionSlot slot) async {
    final prefs = await SharedPreferences.getInstance();
    final assignedMap = await _getAssignedMap(prefs);
    final todaysSlots = assignedMap[_todayString()];
    return todaysSlots != null && todaysSlots.containsKey(slot.storageKey);
  }

  /// Returns [slot]'s reflection if already assigned today, without
  /// triggering a pick. Null if nothing's been picked yet for that slot.
  Future<EmbeddedReflection?> getSlotIfAssigned(ReflectionSlot slot) async {
    final prefs = await SharedPreferences.getInstance();
    final assignedMap = await _getAssignedMap(prefs);
    final existingId = assignedMap[_todayString()]?[slot.storageKey];
    if (existingId == null) return null;

    final all = await _embeddingService.allReflections();
    final existing = all.where((r) => r.id == existingId);
    return existing.isNotEmpty ? existing.first : null;
  }

  /// Every date's ambient (Morning/Evening) picks, most recent first --
  /// each date deduplicated to at most one id per slot, since that's
  /// exactly what the assignment map already stores (rerolls of the
  /// on-demand slot overwrite in place rather than piling up, but this
  /// method skips on-demand entirely regardless -- see [DailyHeadline]).
  /// Dates where neither ambient slot was ever assigned are omitted.
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

  /// date -> {slot -> reflectionId}
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

  /// History entries as {"id": ..., "date": "yyyy-MM-dd", "slot": ...},
  /// newest last. [slot] is informational (e.g. for a future archive
  /// screen) — recency exclusion below ignores it deliberately, so a
  /// reflection shown as this morning's pick won't turn right around
  /// as tonight's pick either.
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

  /// Ids shown within the last [windowDays] days, across all slots,
  /// used to keep any pick from repeating something shown recently
  /// regardless of which slot showed it. [windowDays] defaults to
  /// [recencyWindowDays] but callers (see [_rankWithRelaxedRecency]) can
  /// pass a smaller value to progressively relax the exclusion.
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

  /// Full shown-reflection history, most recent first. Each entry
  /// carries which slot showed it. Note this includes every reroll of
  /// the on-demand slot as a separate entry (that's what recency
  /// exclusion needs) -- for a deduplicated "one pick per day" view,
  /// use [getDailyHeadlines] instead.
  Future<List<Map<String, String>>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = await _getHistory(prefs);
    return history.reversed.toList();
  }
}