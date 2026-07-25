import 'package:flutter/material.dart';
import '../models/context_option.dart';
import '../services/reflection_embedding_service.dart';

/// The three possible outcomes of showing [MoodCheckInSheet], replacing
/// the old `String?` return value. Overloading null to mean "cancelled"
/// left no way to express "explicitly skipped" (which should still
/// trigger a pick — just via the random path, per the no-mood-given
/// design decision) versus "cancelled" (which should leave whatever
/// slot called this alone, no pick at all).
///
/// Callers should exhaustively switch over this (sealed class, so the
/// analyzer will flag a missing case):
///
/// ```dart
/// final result = await MoodCheckInSheet.show(context);
/// switch (result) {
///   case MoodPicked(:final moodId):
///     // rank + pick using moodId
///   case MoodSkipped():
///     // random pick, no ranking
///   case MoodCancelled():
///     // leave the slot untouched
/// }
/// ```
sealed class MoodCheckInResult {
  const MoodCheckInResult();
}

/// A mood chip was selected and confirmed via "Continue".
class MoodPicked extends MoodCheckInResult {
  final String moodId;
  const MoodPicked(this.moodId);
}

/// User tapped "I don't know" — no mood chip selection is implied or
/// required. Distinct from [MoodCancelled]: this should still result in
/// a fresh pick, just via the random path rather than embedding rank.
class MoodSkipped extends MoodCheckInResult {
  const MoodSkipped();
}

/// Sheet was dismissed without an explicit choice. Distinct from
/// [MoodSkipped]: callers should leave today's slot as-is rather than
/// picking anything.
class MoodCancelled extends MoodCheckInResult {
  const MoodCancelled();
}

/// A quiet, single-question check-in: "how are you, right now?" —
/// shown before a slot's reflection is picked, whenever that slot
/// hasn't been picked yet today. Options are loaded live from
/// context_options.json (category: 'mood'), so this UI can never drift
/// out of sync with what the matcher actually knows how to compare
/// against.
///
/// Returns a [MoodCheckInResult] via [show] — see that class's doc for
/// the three possible outcomes and why they're kept distinct.
class MoodCheckInSheet extends StatefulWidget {
  final ReflectionEmbeddingService embeddingService;

  const MoodCheckInSheet({super.key, required this.embeddingService});

  /// Convenience: shows the sheet and returns the [MoodCheckInResult].
  /// A dismissal with nothing selected (tapping the backdrop, since
  /// drag-to-dismiss stays off to avoid accidental swipes) maps to
  /// [MoodCancelled] here, so callers never have to treat a bare
  /// `null` as a fourth, unhandled case.
  static Future<MoodCheckInResult> show(
    BuildContext context, {
    ReflectionEmbeddingService? embeddingService,
  }) async {
    final result = await showModalBottomSheet<MoodCheckInResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: false,
      builder: (_) => MoodCheckInSheet(
        embeddingService: embeddingService ?? ReflectionEmbeddingService(),
      ),
    );
    return result ?? const MoodCancelled();
  }

  @override
  State<MoodCheckInSheet> createState() => _MoodCheckInSheetState();
}

class _MoodCheckInSheetState extends State<MoodCheckInSheet> {
  List<ContextOption>? _moods;
  String? _selectedId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final moods = await widget.embeddingService.contextOptions(
      category: 'mood',
    );
    if (!mounted) return;
    setState(() {
      _moods = moods;
      _loading = false;
    });
  }

  void _confirm() {
    if (_selectedId == null) return;
    Navigator.of(context).pop(MoodPicked(_selectedId!));
  }

  void _skip() {
    Navigator.of(context).pop(const MoodSkipped());
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFFBF3E9),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'How are you, right now?',
                    style: TextStyle(
                      fontSize: 18,
                      fontStyle: FontStyle.italic,
                      fontFamily: 'Georgia',
                      color: Color(0xFF3B2E28),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'This just shapes today\'s reflection — nothing is saved beyond that.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF8A6F5C)),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: _moods!.map((mood) {
                      final selected = mood.id == _selectedId;
                      return _MoodChip(
                        label: mood.label,
                        selected: selected,
                        onTap: () => setState(() => _selectedId = mood.id),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _selectedId == null ? null : _confirm,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFB5651D),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Continue'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Explicit skip, independent of chip selection — picking
                  // this always feeds the random path (decision 3),
                  // regardless of whether a chip happens to be selected.
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: _skip,
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF8A6F5C),
                      ),
                      child: const Text('I don\'t know — surprise me'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _MoodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MoodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFD8C3AE) : const Color(0xFFF0E4D4),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? const Color(0xFFB5651D)
                : Colors.transparent,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: const Color(0xFF3B2E28),
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}