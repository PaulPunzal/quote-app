import 'package:flutter/material.dart';
import '../models/embedded_reflection.dart';
import '../services/reflection_embedding_service.dart';

/// Lists every reflection in assets/reflections.json, with a simple text
/// search. Replaces the old tag/author-filtered Quote browser — reflections
/// don't carry manual tags, they're matched by mood/weather/time embeddings
/// instead, which a filter dropdown can't meaningfully expose.
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  final ReflectionEmbeddingService _embeddingService =
      ReflectionEmbeddingService();

  List<EmbeddedReflection> _all = [];
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _embeddingService.allReflections();
    if (!mounted) return;
    setState(() {
      _all = all;
      _loading = false;
    });
  }

  List<EmbeddedReflection> get _filtered {
    if (_query.trim().isEmpty) return _all;
    final q = _query.trim().toLowerCase();
    return _all.where((r) => r.text.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9),
      appBar: AppBar(
        title: const Text('All Reflections'),
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${_filtered.length} reflection'
                      '${_filtered.length == 1 ? '' : 's'}',
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
                          child: Text('No reflections match your search.'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _filtered.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 28),
                          itemBuilder: (context, index) {
                            return _ReflectionTile(
                                reflection: _filtered[index]);
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _ReflectionTile extends StatelessWidget {
  final EmbeddedReflection reflection;
  const _ReflectionTile({required this.reflection});

  @override
  Widget build(BuildContext context) {
    return Text(
      reflection.text,
      style: const TextStyle(
        fontSize: 16,
        fontStyle: FontStyle.italic,
        height: 1.4,
        color: Color(0xFF3B2E28),
        fontFamily: 'Georgia',
      ),
    );
  }
}