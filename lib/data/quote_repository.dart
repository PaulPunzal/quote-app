import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models/quote.dart';

/// Loads the bundled quote pool from assets/quotes.json.
/// This is a one-time load into memory — no network, no server.
class QuoteRepository {
  static const String _assetPath = 'assets/quotes.json';

  List<Quote>? _cache;

  /// Loads (and caches) all quotes from the local JSON asset.
  Future<List<Quote>> loadAll() async {
    if (_cache != null) return _cache!;

    final raw = await rootBundle.loadString(_assetPath);
    final Map<String, dynamic> decoded = jsonDecode(raw) as Map<String, dynamic>;
    final List<dynamic> list = decoded['quotes'] as List<dynamic>;

    _cache = list
        .map((item) => Quote.fromJson(item as Map<String, dynamic>))
        .toList();

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
}
