import 'package:flutter/material.dart';
import '../models/quote.dart';
import '../data/quote_repository.dart';
import '../data/quote_categories.dart';

/// A simple form for adding your own quote to the pool. Saved quotes
/// join the daily rotation immediately and show up in the Browse screen.
class AddQuoteScreen extends StatefulWidget {
  const AddQuoteScreen({super.key});

  @override
  State<AddQuoteScreen> createState() => _AddQuoteScreenState();
}

class _AddQuoteScreenState extends State<AddQuoteScreen> {
  final _formKey = GlobalKey<FormState>();
  final _textController = TextEditingController();
  final _authorController = TextEditingController();
  final _newCategoryController = TextEditingController();

  final QuoteRepository _repository = QuoteRepository();

  // Starts with the curated list; grows only if the user adds a genuinely
  // new category below, so choices stay consistent instead of free-typed.
  List<String> _availableCategories = List.of(kQuoteCategories);
  final Set<String> _selectedCategories = {};

  bool _saving = false;

  @override
  void dispose() {
    _textController.dispose();
    _authorController.dispose();
    _newCategoryController.dispose();
    super.dispose();
  }

  void _addNewCategory() {
    final normalized = normalizeCategory(_newCategoryController.text);
    if (normalized.isEmpty) return;

    setState(() {
      if (!_availableCategories.contains(normalized)) {
        _availableCategories = [..._availableCategories, normalized]..sort();
      }
      _selectedCategories.add(normalized);
      _newCategoryController.clear();
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    final quote = Quote(
      id: '', // real id is assigned by CustomQuoteService on save
      text: _textController.text.trim(),
      author: _authorController.text.trim(),
      tags: _selectedCategories.toList(),
    );

    await _repository.addCustomQuote(quote);

    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9),
      appBar: AppBar(
        title: const Text('Add a Quote'),
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _textController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Quote text',
                  alignLabelWithHint: true,
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Please enter the quote text'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _authorController,
                decoration: const InputDecoration(
                  labelText: 'Author (optional)',
                  hintText: 'Unknown',
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Categories (optional)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF3B2E28),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _availableCategories.map((category) {
                  final selected = _selectedCategories.contains(category);
                  return FilterChip(
                    label: Text(displayCategory(category)),
                    selected: selected,
                    selectedColor: const Color(0xFFD8C3AE),
                    backgroundColor: const Color(0xFFF0E4D4),
                    onSelected: (value) {
                      setState(() {
                        if (value) {
                          _selectedCategories.add(category);
                        } else {
                          _selectedCategories.remove(category);
                        }
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newCategoryController,
                      decoration: const InputDecoration(
                        labelText: 'Add a new category',
                        hintText: 'e.g. gratitude',
                      ),
                      onSubmitted: (_) => _addNewCategory(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    tooltip: 'Add category',
                    onPressed: _addNewCategory,
                  ),
                ],
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Save quote'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}