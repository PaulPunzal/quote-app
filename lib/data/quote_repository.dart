import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models/quote.dart';
import '../services/custom_quote_service.dart';
import 'quote_categories.dart';

/// Loads the full quote pool: the bundled quotes from assets/quotes.json
/// plus any quotes the user has added themselves on-device (see
/// [CustomQuoteService]). Everything is combined and cached in memory.
class QuoteRepository {
  static const String _assetPath = 'assets/quotes.json';

  final CustomQuoteService _customQuotes;

  List<Quote>? _cache;

  QuoteRepository({CustomQuoteService? customQuoteService})
      : _customQuotes = customQuoteService ?? CustomQuoteService();

  /// Loads (and caches) all quotes: bundled + user-added, in that order.
  Future<List<Quote>> loadAll() async {
    if (_cache != null) return _cache!;

    final raw = await rootBundle.loadString(_assetPath);
    final Map<String, dynamic> decoded =
        jsonDecode(raw) as Map<String, dynamic>;
    final List<dynamic> list = decoded['quotes'] as List<dynamic>;

    final bundled = list
        .map((item) => Quote.fromJson(item as Map<String, dynamic>))
        .toList();

    final custom = await _customQuotes.getAll();

    _cache = [...bundled, ...custom];
    return _cache!;
  }

  /// Convenience: fetch a single quote by id, or null if not found.
  Future<Quote?> getById(String id) async {
    final all = await loadAll();
    try {
      return all.firstWhere((q) => q.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Adds a new user-created quote, persists it, and refreshes the
  /// in-memory cache so it's immediately available for browsing and
  /// future day-to-day rotation. Returns the saved quote (with its
  /// assigned id).
  Future<Quote> addCustomQuote(Quote quote) async {
    final saved = await _customQuotes.addQuote(quote);
    _cache = null; // force reload on next loadAll()
    return saved;
  }

  /// All available tags: the curated category list plus anything else
  /// that happens to show up in the data (e.g. leftover legacy tags),
  /// sorted alphabetically. Used to populate the category filter on the
  /// Browse screen and the category picker on Add Quote.
  Future<List<String>> allTags() async {
    final all = await loadAll();
    final tags = <String>{...kQuoteCategories};
    for (final q in all) {
      tags.addAll(q.tags);
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  /// All distinct authors across the current pool, sorted alphabetically.
  /// Used to populate the author filter on the Browse screen.
  Future<List<String>> allAuthors() async {
    final all = await loadAll();
    final authors = all.map((q) => q.author).toSet().toList()..sort();
    return authors;
  }
}