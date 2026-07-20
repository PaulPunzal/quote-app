import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/quote.dart';
import '../data/quote_repository.dart';
import '../data/quote_categories.dart';

/// Lets the user paste a JSON blob of quotes (or pick a .json file) and
/// import them all at once. Accepts either `{"quotes": [...]}` (matching
/// assets/quotes.json) or a bare `[...]` array. Extra fields per item
/// (like "book") are simply ignored — only "text" (required), "author"
/// (optional), and "tags" (optional) are read. Any "id" in the input is
/// ignored too; CustomQuoteService always assigns its own ids.
class BulkImportScreen extends StatefulWidget {
  const BulkImportScreen({super.key});

  @override
  State<BulkImportScreen> createState() => _BulkImportScreenState();
}

class _BulkImportScreenState extends State<BulkImportScreen> {
  final _jsonController = TextEditingController();
  final QuoteRepository _repository = QuoteRepository();

  List<Quote>? _preview;
  List<String> _skipped = [];
  String? _error;
  bool _importing = false;

  @override
  void dispose() {
    _jsonController.dispose();
    super.dispose();
  }

  void _parse() {
    final input = _jsonController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _error = 'Paste some JSON first.';
        _preview = null;
      });
      return;
    }

    try {
      final decoded = jsonDecode(input);

      List<dynamic> rawList;
      if (decoded is Map<String, dynamic> && decoded['quotes'] is List) {
        rawList = decoded['quotes'] as List;
      } else if (decoded is List) {
        rawList = decoded;
      } else {
        throw const FormatException(
          'Expected a JSON array of quotes, or an object with a '
          '"quotes" array.',
        );
      }

      if (rawList.isEmpty) {
        throw const FormatException('No quotes found in that JSON.');
      }

      final parsed = <Quote>[];
      final skipped = <String>[];

      for (var i = 0; i < rawList.length; i++) {
        final item = rawList[i];
        if (item is! Map<String, dynamic>) {
          skipped.add('Item ${i + 1}: not a JSON object');
          continue;
        }

        final text = (item['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) {
          skipped.add('Item ${i + 1}: missing "text"');
          continue;
        }

        final author = (item['author'] as String?)?.trim() ?? '';
        final tags = (item['tags'] as List<dynamic>?)
                ?.map((t) => t.toString())
                .toList() ??
            const <String>[];

        parsed.add(Quote(id: '', text: text, author: author, tags: tags));
      }

      if (parsed.isEmpty) {
        throw const FormatException(
          'None of the items had usable text — nothing to import.',
        );
      }

      setState(() {
        _preview = parsed;
        _skipped = skipped;
        _error = null;
      });
    } catch (_) {
      setState(() {
        _preview = null;
        _error = 'Could not parse that JSON. Check the format and try again.';
      });
    }
  }

  Future<void> _pickFile() async {
    setState(() => _error = null);

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true, // ensures bytes are available on every platform
    );
    if (result == null || result.files.isEmpty) return; // user cancelled

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      setState(() => _error = 'Could not read that file.');
      return;
    }

    final content = utf8.decode(bytes);
    _jsonController.text = content;
    _parse(); // jump straight to preview
  }

  void _editAgain() {
    setState(() {
      _preview = null;
      _skipped = [];
      _error = null;
    });
  }

  Future<void> _import() async {
    if (_preview == null || _preview!.isEmpty) return;

    setState(() => _importing = true);
    await _repository.addCustomQuotes(_preview!);

    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9),
      appBar: AppBar(
        title: const Text('Bulk Import'),
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: _preview == null ? _buildEditor() : _buildPreview(),
      ),
    );
  }

  Widget _buildEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Paste a JSON array of quotes, or an object with a "quotes" '
          'array — same shape as assets/quotes.json. Each item needs '
          '"text"; "author" and "tags" are optional.',
          style: TextStyle(fontSize: 13, color: Color(0xFF8A6F5C)),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: TextField(
            controller: _jsonController,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              alignLabelWithHint: true,
              hintText:
                  '{\n  "quotes": [\n    {"text": "...", "author": "..."}\n  ]\n}',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickFile,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Choose JSON file'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _parse,
                child: const Text('Preview import'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPreview() {
    final preview = _preview!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${preview.length} quote${preview.length == 1 ? '' : 's'} ready to import',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF3B2E28),
          ),
        ),
        if (_skipped.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '${_skipped.length} skipped: ${_skipped.join('; ')}',
            style: const TextStyle(fontSize: 12, color: Colors.red),
          ),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: ListView.separated(
            itemCount: preview.length,
            separatorBuilder: (_, __) => const Divider(height: 20),
            itemBuilder: (context, index) {
              final q = preview[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '"${q.text}"',
                    style: const TextStyle(
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                      color: Color(0xFF3B2E28),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '— ${q.author.isEmpty ? 'Unknown' : q.author}'
                    '${q.tags.isEmpty ? '' : '  ·  ${q.tags.map(displayCategory).join(', ')}'}',
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFF8A6F5C)),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _importing ? null : _editAgain,
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _importing ? null : _import,
                child: _importing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text('Import ${preview.length}'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}