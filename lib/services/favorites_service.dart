import 'package:shared_preferences/shared_preferences.dart';

/// Tracks which reflection ids the user has favorited. Deliberately
/// tiny — just a set of ids under one SharedPreferences key, same
/// on-device-only pattern as the rest of this app's storage. Favoriting
/// works the same for every reflection regardless of source (bundled,
/// picked for a slot, or later a custom one), since it's keyed purely
/// by id and doesn't care about embeddings.
///
/// Also tracks, separately, the date each currently-favorited id was
/// most recently favorited on -- this exists purely so the History
/// screen can show "what got favorited today" alongside the day's
/// ambient picks. It's a lightweight side record, not the source of
/// truth for "is this favorited" (that's still [getAll]/[isFavorite]);
/// removing a favorite also removes its date entry.
class FavoritesService {
  static const _key = 'favorite_reflection_ids';
  static const _datesKey = 'favorite_reflection_dates';

  Future<Set<String>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const []).toSet();
  }

  Future<bool> isFavorite(String id) async {
    final all = await getAll();
    return all.contains(id);
  }

  /// Flips [id]'s favorited state and returns the updated full set, so
  /// callers can just replace their local copy instead of re-reading.
  Future<Set<String>> toggle(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await getAll();

    final wasFavorite = all.remove(id);
    if (!wasFavorite) {
      all.add(id);
    }
    await prefs.setStringList(_key, all.toList());

    // becomingFavorite == !wasFavorite: record today's date when it's
    // newly favorited, drop the date record when un-favorited.
    final dates = await _getDatesMap(prefs);
    if (!wasFavorite) {
      dates[id] = _todayString();
    } else {
      dates.remove(id);
    }
    await _saveDatesMap(prefs, dates);

    return all;
  }

  /// reflectionId -> yyyy-MM-dd it was most recently favorited on.
  /// Only covers favorites made since this tracking was added --
  /// anything favorited before that has no date here (it still shows
  /// up fine in the plain Favorites list, just won't appear "under" a
  /// specific day in History).
  Future<Map<String, String>> getFavoritedDates() async {
    final prefs = await SharedPreferences.getInstance();
    return _getDatesMap(prefs);
  }

  Future<Map<String, String>> _getDatesMap(SharedPreferences prefs) async {
    final raw = prefs.getStringList(_datesKey) ?? const [];
    final map = <String, String>{};
    for (final entry in raw) {
      final separatorIndex = entry.indexOf('|');
      if (separatorIndex == -1) continue;
      map[entry.substring(0, separatorIndex)] =
          entry.substring(separatorIndex + 1);
    }
    return map;
  }

  Future<void> _saveDatesMap(
    SharedPreferences prefs,
    Map<String, String> map,
  ) async {
    final encoded = map.entries.map((e) => '${e.key}|${e.value}').toList();
    await prefs.setStringList(_datesKey, encoded);
  }

  static String _todayString() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '${now.year}-$mm-$dd';
  }
}