import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/quote.dart';
import '../data/quote_categories.dart';

/// Persists quotes the user adds themselves, kept separate from the
/// bundled assets/quotes.json pool. Stored on-device only, as a simple
/// JSON list under one SharedPreferences key.
class CustomQuoteService {
  static const _key = 'custom_quotes';

  /// Returns all user-added quotes, in the order they were added.
  Future<List<Quote>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];

    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => Quote.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Saves [quote], assigning it a fresh unique id (any incoming id is
  /// ignored — the caller doesn't need to worry about collisions).
  /// Returns the quote as actually stored, id included.
  Future<Quote> addQuote(Quote quote) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getAll();

    final normalizedTags = quote.tags
        .map(normalizeCategory)
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList();

    final saved = Quote(
      id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
      text: quote.text,
      author: quote.author.trim().isEmpty ? 'Unknown' : quote.author.trim(),
      tags: normalizedTags,
    );

    final updated = [...existing, saved];
    await prefs.setString(
      _key,
      jsonEncode(updated.map((q) => q.toJson()).toList()),
    );

    return saved;
  }

  /// Removes a user-added quote by id. No-op for bundled quotes, since
  /// those don't live in this store.
  Future<void> deleteQuote(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getAll();
    final updated = existing.where((q) => q.id != id).toList();

    await prefs.setString(
      _key,
      jsonEncode(updated.map((q) => q.toJson()).toList()),
    );
  }
}