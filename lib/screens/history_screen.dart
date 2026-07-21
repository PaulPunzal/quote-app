import 'package:flutter/material.dart';
import '../models/embedded_reflection.dart';
import '../services/favorites_service.dart';
import '../services/reflection_daily_service.dart';
import '../services/reflection_embedding_service.dart';

/// Shows, per day, the two ambient "headline" reflections (Morning and
/// Evening) plus anything favorited that same day -- backed by
/// [ReflectionDailyService.getDailyHeadlines] and
/// [FavoritesService.getFavoritedDates].
///
/// Deliberately does NOT show the on-demand/check-in slot or every
/// reroll of it: that slot is meant to be rerolled freely ("Something
/// else") and isn't a stable "this is the day's reflection" pick the
/// way Morning/Evening are, so including it (or its reroll history)
/// would just be noise here.
///
/// Read-only aside from favoriting: this is a record of what the day
/// looked like, not something you can reroll or edit from here.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final ReflectionDailyService _dailyService = ReflectionDailyService();
  final ReflectionEmbeddingService _embeddingService =
      ReflectionEmbeddingService();
  final FavoritesService _favoritesService = FavoritesService();

  bool _loading = true;
  List<_HistoryDay> _days = [];
  Set<String> _favoriteIds = {};

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final headlines = await _dailyService.getDailyHeadlines();
    final favoritedDates = await _favoritesService.getFavoritedDates();
    final all = await _embeddingService.allReflections();
    final byId = {for (final r in all) r.id: r};
    final favoriteIds = await _favoritesService.getAll();

    // Invert id->date into date->[ids], so each day can list what was
    // favorited on it.
    final favoritedIdsByDate = <String, List<String>>{};
    favoritedDates.forEach((id, date) {
      favoritedIdsByDate.putIfAbsent(date, () => []).add(id);
    });

    // A day is worth showing if it has an ambient headline OR a
    // favorite recorded on it -- either is enough on its own (e.g. you
    // might favorite something in Explore on a day whose headlines
    // haven't loaded yet, or vice versa).
    final allDates = <String>{
      ...headlines.map((h) => h.date),
      ...favoritedIdsByDate.keys,
    }.toList()
      ..sort((a, b) => b.compareTo(a));

    final headlinesByDate = {for (final h in headlines) h.date: h};

    final days = <_HistoryDay>[];
    for (final date in allDates) {
      final headline = headlinesByDate[date];
      final morning =
          headline?.morningId != null ? byId[headline!.morningId] : null;
      final evening =
          headline?.eveningId != null ? byId[headline!.eveningId] : null;

      // Favorited-that-day reflections, excluding whichever of them
      // are already shown as this day's morning/evening headline (no
      // point listing the same reflection twice for one day).
      final headlineIds = {
        if (morning != null) morning.id,
        if (evening != null) evening.id,
      };
      final favorited = (favoritedIdsByDate[date] ?? const [])
          .where((id) => !headlineIds.contains(id))
          .map((id) => byId[id])
          .whereType<EmbeddedReflection>()
          .toList();

      if (morning == null && evening == null && favorited.isEmpty) continue;

      days.add(_HistoryDay(
        date: date,
        morning: morning,
        evening: evening,
        favorited: favorited,
      ));
    }

    if (!mounted) return;
    setState(() {
      _days = days;
      _favoriteIds = favoriteIds;
      _loading = false;
    });
  }

  Future<void> _toggleFavorite(String id) async {
    final updated = await _favoritesService.toggle(id);
    if (!mounted) return;
    setState(() => _favoriteIds = updated);
  }

  String _formatDate(String isoDate) {
    final date = DateTime.tryParse(isoDate);
    if (date == null) return isoDate;
    return '${_months[date.month - 1]} ${date.day}, ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9),
      appBar: AppBar(
        title: const Text('History'),
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _days.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                  itemCount: _days.length,
                  itemBuilder: (context, index) => _buildDay(_days[index]),
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history, size: 28, color: Color(0xFFD8C3AE)),
            const SizedBox(height: 16),
            const Text(
              'No history yet',
              style: TextStyle(
                fontSize: 15,
                fontStyle: FontStyle.italic,
                fontFamily: 'Georgia',
                color: Color(0xFF3B2E28),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Each day\u2019s reflections will collect here over time.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFF8A6F5C)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDay(_HistoryDay day) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _formatDate(day.date),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF8A6F5C),
            ),
          ),
          const SizedBox(height: 12),
          if (day.morning != null)
            _buildEntry(label: 'Morning', reflection: day.morning!),
          if (day.evening != null)
            _buildEntry(label: 'Evening', reflection: day.evening!),
          for (final r in day.favorited)
            _buildEntry(label: 'Favorited', reflection: r),
        ],
      ),
    );
  }

  Widget _buildEntry({
    required String label,
    required EmbeddedReflection reflection,
  }) {
    final isFavorite = _favoriteIds.contains(reflection.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 3),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFF0E4D4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label,
              style: const TextStyle(fontSize: 10, color: Color(0xFF8A6F5C)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              reflection.text,
              style: const TextStyle(
                fontSize: 14,
                fontStyle: FontStyle.italic,
                fontFamily: 'Georgia',
                height: 1.4,
                color: Color(0xFF3B2E28),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(
              isFavorite ? Icons.favorite : Icons.favorite_border,
              size: 16,
              color: const Color(0xFFB5651D),
            ),
            onPressed: () => _toggleFavorite(reflection.id),
          ),
        ],
      ),
    );
  }
}

class _HistoryDay {
  final String date;
  final EmbeddedReflection? morning;
  final EmbeddedReflection? evening;
  final List<EmbeddedReflection> favorited;

  const _HistoryDay({
    required this.date,
    required this.morning,
    required this.evening,
    required this.favorited,
  });
}