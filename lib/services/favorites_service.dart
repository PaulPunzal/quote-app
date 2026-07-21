import 'package:shared_preferences/shared_preferences.dart';

/// Tracks which reflection ids the user has favorited. Deliberately
/// tiny — just a set of ids under one SharedPreferences key, same
/// on-device-only pattern as the rest of this app's storage. Favoriting
/// works the same for every reflection regardless of source (bundled,
/// picked for a slot, or later a custom one), since it's keyed purely
/// by id and doesn't care about embeddings.
class FavoritesService {
  static const _key = 'favorite_reflection_ids';

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
    if (!all.remove(id)) {
      all.add(id);
    }
    await prefs.setStringList(_key, all.toList());
    return all;
  }
}