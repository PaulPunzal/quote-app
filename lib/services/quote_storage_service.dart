import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/quote.dart';
import '../data/quote_repository.dart';

/// A single entry in the shown-quote history/archive.
/// Stores a snapshot of the quote as it appeared that day, so the
/// archive stays accurate even if quotes.json is edited later.
class ShownEntry {
  final String quoteId;
  final String text;
  final String author;
  final String dateShown; // 'yyyy-MM-dd'

  ShownEntry({
    required this.quoteId,
    required this.text,
    required this.author,
    required this.dateShown,
  });

  factory ShownEntry.fromJson(Map<String, dynamic> json) => ShownEntry(
        quoteId: json['quoteId'] as String,
        text: json['text'] as String,
        author: json['author'] as String,
        dateShown: json['dateShown'] as String,
      );

  Map<String, dynamic> toJson() => {
        'quoteId': quoteId,
        'text': text,
        'author': author,
        'dateShown': dateShown,
      };
}

/// Handles all local persistence: which quote is "today's", the
/// rotation pool (so quotes don't repeat until the set cycles), and
/// the full history used by the archive screen. Everything here is
/// on-device only — no network, no server.
class QuoteStorageService {
  static const _keyAssignedQuotes = 'assigned_quotes'; // date -> quoteId map
  static const _keyCycleShownIds = 'cycle_shown_ids'; // ids used since last full cycle
  static const _keyHistory = 'shown_history';

  final QuoteRepository _repository;

  QuoteStorageService({QuoteRepository? repository})
      : _repository = repository ?? QuoteRepository();

  String _todayString() => dateToString(DateTime.now());

  static String dateToString(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  /// Returns today's quote — either the one already picked earlier
  /// today, or a freshly chosen one if this is the first open of the day.
  Future<Quote> getTodaysQuote() async {
    return getOrAssignQuoteForDate(_todayString());
  }

  /// Returns the quote assigned to [dateString] ('yyyy-MM-dd'), assigning
  /// one from the rotation pool if this date doesn't have one yet.
  /// Used both for "today's" quote and for pre-computing tomorrow's
  /// quote so the notification can show real content, not a placeholder.
  Future<Quote> getOrAssignQuoteForDate(String dateString) async {
    final prefs = await SharedPreferences.getInstance();
    final allQuotes = await _repository.loadAll();
    final assignedMap = await _getAssignedMap(prefs);

    final existingId = assignedMap[dateString];
    if (existingId != null) {
      final existing = allQuotes.where((q) => q.id == existingId);
      if (existing.isNotEmpty) return existing.first;
      // Stored id no longer exists (quotes.json was edited) — fall
      // through and assign a new one below.
    }

    final picked = await _pickNextQuote(prefs, allQuotes);

    assignedMap[dateString] = picked.id;
    await _saveAssignedMap(prefs, assignedMap);
    await _appendToHistory(prefs, picked, dateString);

    return picked;
  }

  Future<Map<String, String>> _getAssignedMap(SharedPreferences prefs) async {
    final raw = prefs.getString(_keyAssignedQuotes);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, v as String));
  }

  Future<void> _saveAssignedMap(
      SharedPreferences prefs, Map<String, String> map) async {
    await prefs.setString(_keyAssignedQuotes, jsonEncode(map));
  }

  /// Picks a quote not yet used in the current rotation cycle.
  /// Once every quote has been shown, the cycle resets and all
  /// quotes become eligible again.
  Future<Quote> _pickNextQuote(
      SharedPreferences prefs, List<Quote> allQuotes) async {
    final cycleShownIds = prefs.getStringList(_keyCycleShownIds) ?? [];

    var eligible =
        allQuotes.where((q) => !cycleShownIds.contains(q.id)).toList();

    if (eligible.isEmpty) {
      // Full cycle complete — reset and make everything eligible again.
      eligible = List.from(allQuotes);
      await prefs.setStringList(_keyCycleShownIds, []);
    }

    final picked = eligible[Random().nextInt(eligible.length)];

    final updatedCycle = List<String>.from(
        prefs.getStringList(_keyCycleShownIds) ?? [])
      ..add(picked.id);
    await prefs.setStringList(_keyCycleShownIds, updatedCycle);

    return picked;
  }

  Future<void> _appendToHistory(
      SharedPreferences prefs, Quote quote, String date) async {
    final history = await getHistory();

    // Avoid duplicate entries if getTodaysQuote() is somehow called
    // twice on the same day for the same quote.
    final alreadyLogged =
        history.any((e) => e.dateShown == date && e.quoteId == quote.id);
    if (alreadyLogged) return;

    history.insert(
      0,
      ShownEntry(
        quoteId: quote.id,
        text: quote.text,
        author: quote.author,
        dateShown: date,
      ),
    );

    final encoded = jsonEncode(history.map((e) => e.toJson()).toList());
    await prefs.setString(_keyHistory, encoded);
  }

  /// Returns the full shown-quote history, newest first.
  Future<List<ShownEntry>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyHistory);
    if (raw == null) return [];

    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => ShownEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}