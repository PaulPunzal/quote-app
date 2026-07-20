import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'reflection_embedding_service.dart';
import '../models/embedded_reflection.dart';

/// Picks and persists "today's reflection", the same way the old
/// QuoteStorageService picked "today's quote" — once assigned for a
/// date, it stays fixed for that whole day.
///
/// The difference from the old tag-based system: picking is no longer
/// "grab anything untagged-yet from a shuffled pool." It's:
///   1. build a context vector from mood + weather + time,
///   2. rank all 100 reflections by similarity to that vector,
///   3. drop anything shown in the last [recencyWindowDays] days,
///   4. randomly sample from the top [topPoolSize] remaining —
///      not always the single best match, so it doesn't feel like
///      the same handful of "very calm" reflections every time.
class ReflectionDailyService {
  static const _keyAssignedReflections =
      'assigned_reflections'; // date -> reflection id
  static const _keyHistory = 'reflection_shown_history'; // list of {id,date}

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

  /// Returns today's reflection, picking a new one only if today
  /// doesn't have one assigned yet. [moodId] and [weatherId] should be
  /// ids from context_options.json (e.g. 'mood_tired', 'weather_rainy');
  /// [weatherId] can be omitted if you don't have a weather reading yet.
  /// The time bucket is always computed automatically from the clock.
  ///
  /// Note: because today's reflection is cached the first time it's
  /// picked, calling this again later in the same day with a
  /// *different* mood won't change the result — matching your app's
  /// existing "today's pick is fixed once made" behavior.
  Future<EmbeddedReflection> getTodaysReflection({
    required String moodId,
    String? weatherId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayString();

    final assignedMap = await _getAssignedMap(prefs);
    final existingId = assignedMap[today];
    if (existingId != null) {
      final all = await _embeddingService.allReflections();
      final existing = all.where((r) => r.id == existingId);
      if (existing.isNotEmpty) return existing.first;
      // Stored id no longer exists (reflections.json changed) — fall
      // through and pick a fresh one below.
    }

    final timeId = timeBucketIdForHour(DateTime.now().hour);
    final contextVector = await _embeddingService.buildContextVector(
      moodId: moodId,
      weatherId: weatherId,
      timeId: timeId,
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

    assignedMap[today] = picked.id;
    await _saveAssignedMap(prefs, assignedMap);
    await _appendToHistory(prefs, picked.id, today);

    return picked;
  }

  /// True if today's reflection has already been picked (and would
  /// just be returned as-is by getTodaysReflection). Lets the UI skip
  /// the mood check-in entirely on a second open of the app the same day.
  Future<bool> hasTodaysAssignment() async {
    final prefs = await SharedPreferences.getInstance();
    final assignedMap = await _getAssignedMap(prefs);
    return assignedMap.containsKey(_todayString());
  }

  /// Returns today's reflection if one is already assigned, without
  /// requiring a mood id. Returns null if nothing has been picked yet
  /// today (i.e. the mood check-in still needs to happen).
  Future<EmbeddedReflection?> getTodaysReflectionIfAssigned() async {
    final prefs = await SharedPreferences.getInstance();
    final assignedMap = await _getAssignedMap(prefs);
    final existingId = assignedMap[_todayString()];
    if (existingId == null) return null;

    final all = await _embeddingService.allReflections();
    final existing = all.where((r) => r.id == existingId);
    return existing.isNotEmpty ? existing.first : null;
  }

  Future<Map<String, String>> _getAssignedMap(SharedPreferences prefs) async {
    final raw = prefs.getString(_keyAssignedReflections);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, v as String));
  }

  Future<void> _saveAssignedMap(
      SharedPreferences prefs, Map<String, String> map) async {
    await prefs.setString(_keyAssignedReflections, jsonEncode(map));
  }

  /// History entries as {"id": ..., "date": "yyyy-MM-dd"}, newest last.
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
      SharedPreferences prefs, String reflectionId, String date) async {
    final history = await _getHistory(prefs);
    history.add({'id': reflectionId, 'date': date});
    await prefs.setString(_keyHistory, jsonEncode(history));
  }

  /// Ids shown within the last [recencyWindowDays] days, used to keep
  /// today's pick from repeating something you saw last week.
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
  /// archive screen, same idea as the old QuoteStorageService.getHistory().
  Future<List<Map<String, String>>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = await _getHistory(prefs);
    return history.reversed.toList();
  }
}