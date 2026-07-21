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
/// Picking mechanics (ranking, recency exclusion, pool sampling) are
/// unchanged from the original single-slot version — see the class doc
/// in the git history if you want the "why" on the ranking approach.
/// What's new here is purely the slot dimension.
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
    this.topPoolSize = 6,
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

    final recentIds = await _recentlyShownIds(prefs);
    var ranked = await _embeddingService.rank(
      contextVector,
      excludeIds: recentIds,
    );

    // If recency filtering wiped out (almost) everything -- small
    // corpora can hit this -- fall back to ranking without the filter
    // rather than crashing or repeating the exact same reflection.
    if (ranked.isEmpty) {
      ranked = await _embeddingService.rank(contextVector);
    }

    final poolSize = min(topPoolSize, ranked.length);
    final pool = ranked.take(poolSize).toList();
    final picked = pool[_random.nextInt(pool.length)].reflection;

    todaysSlots[slot.storageKey] = picked.id;
    assignedMap[today] = todaysSlots;
    await _saveAssignedMap(prefs, assignedMap);
    await _appendToHistory(prefs, picked.id, today, slot.storageKey);

    return picked;
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

  /// Ids shown within the last [recencyWindowDays] days, across all
  /// slots, used to keep any pick from repeating something shown
  /// recently regardless of which slot showed it.
  Future<Set<String>> _recentlyShownIds(SharedPreferences prefs) async {
    final history = await _getHistory(prefs);
    final cutoff =
        DateTime.now().subtract(Duration(days: recencyWindowDays));

    final recent = <String>{};
    for (final entry in history) {
      final date = DateTime.tryParse(entry['date'] ?? '');
      if (date != null && date.isAfter(cutoff)) {
        recent.add(entry['id']!);
      }
    }
    return recent;
  }

  /// Full shown-reflection history, most recent first. Useful for an
  /// archive screen; each entry now also carries which slot showed it.
  Future<List<Map<String, String>>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = await _getHistory(prefs);
    return history.reversed.toList();
  }
}