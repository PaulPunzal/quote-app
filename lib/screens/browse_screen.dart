import 'package:flutter/material.dart';
import '../models/quote.dart';
import '../data/quote_repository.dart';
import '../data/quote_categories.dart';

/// Lists every quote in the pool (bundled + user-added), with simple
/// filtering by category (tag) and by author. This is purely a browsing
/// view — tapping around here never changes which quote is "today's".
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  final QuoteRepository _repository = QuoteRepository();

  List<Quote> _all = [];
  List<String> _tags = [];
  List<String> _authors = [];

  String? _selectedTag; // null = all categories
  String? _selectedAuthor; // null = all authors
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _repository.loadAll();
    final tags = await _repository.allTags();
    final authors = await _repository.allAuthors();

    if (!mounted) return;
    setState(() {
      _all = all;
      _tags = tags;
      _authors = authors;
      _loading = false;
    });
  }

  List<Quote> get _filtered {
    return _all.where((q) {
      final matchesTag = _selectedTag == null || q.tags.contains(_selectedTag);
      final matchesAuthor =
          _selectedAuthor == null || q.author == _selectedAuthor;
      return matchesTag && matchesAuthor;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9),
      appBar: AppBar(
        title: const Text('All Quotes'),
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildFilters(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${_filtered.length} quote${_filtered.length == 1 ? '' : 's'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF8A6F5C),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: _filtered.isEmpty
                      ? const Center(
                          child: Text('No quotes match those filters.'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _filtered.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 28),
                          itemBuilder: (context, index) {
                            return _QuoteTile(quote: _filtered[index]);
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String?>(
              initialValue: _selectedTag,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('All categories')),
                ..._tags.map(
                  (t) => DropdownMenuItem(
                    value: t,
                    child: Text(displayCategory(t),
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: (value) => setState(() => _selectedTag = value),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String?>(
              initialValue: _selectedAuthor,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Author'),
              items: [
                const DropdownMenuItem(
                    value: null, child: Text('All authors')),
                ..._authors.map(
                  (a) => DropdownMenuItem(
                    value: a,
                    child: Text(a, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: (value) => setState(() => _selectedAuthor = value),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuoteTile extends StatelessWidget {
  final Quote quote;
  const _QuoteTile({required this.quote});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '"${quote.text}"',
          style: const TextStyle(
            fontSize: 16,
            fontStyle: FontStyle.italic,
            height: 1.4,
            color: Color(0xFF3B2E28),
            fontFamily: 'Georgia',
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '— ${quote.author}',
          style: const TextStyle(fontSize: 13, color: Color(0xFF8A6F5C)),
        ),
        if (quote.tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: quote.tags
                .map(
                  (t) => Chip(
                    label: Text(displayCategory(t),
                        style: const TextStyle(fontSize: 11)),
                    backgroundColor: const Color(0xFFF0E4D4),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide.none,
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );
  }
}