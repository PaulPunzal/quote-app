import 'package:flutter/material.dart';
import '../../../models/embedded_reflection.dart';
import 'favoritable_reflection.dart';
import 'quiet_loading_dot.dart';

/// The single slot view now shown for whichever slot (Morning or
/// Evening) the clock says is current -- replaces the old
/// `AmbientTab` + `OnDemandTab` pair, which existed only because the
/// old design had a third, structurally-different "Check in" tab.
/// Since every slot is now picked the same way (mood-ranked or
/// random -- see ReflectionDailyService), one widget covers every
/// state a slot can be in:
///
///   - [loading]: fetching or picking, show a quiet loading dot.
///   - [reflection] null + [needsCheckIn] true: not yet picked today --
///     show the "Check in with yourself" prompt.
///   - [reflection] non-null: display it, with a reroll button (unless
///     [isReadOnly]) and a "See other reflections" entry into Explore.
///
/// [isReadOnly] is true only for the rare pre-5am carryover view of
/// yesterday's already-finished Evening reflection (decision 6) --
/// rerolling or re-prompting mood for a slot that's already over
/// wouldn't make sense, so the reroll button is hidden in that case.
/// Explore is still offered even when read-only; browsing isn't
/// mutating anything.
class ReflectionSlotView extends StatelessWidget {
  final EmbeddedReflection? reflection;
  final bool loading;
  final bool needsCheckIn;
  final bool isReadOnly;
  final Animation<double> fadeAnimation;
  final Set<String> favoriteIds;
  final ValueChanged<String> onToggleFavorite;
  final VoidCallback onCheckIn;
  final VoidCallback onReroll;
  final bool canReroll;
  final VoidCallback onExplore;

  const ReflectionSlotView({
    super.key,
    required this.reflection,
    required this.loading,
    required this.needsCheckIn,
    required this.isReadOnly,
    required this.fadeAnimation,
    required this.favoriteIds,
    required this.onToggleFavorite,
    required this.onCheckIn,
    required this.onReroll,
    required this.canReroll,
    required this.onExplore,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: QuietLoadingDot());
    }

    final current = reflection;
    if (current == null) {
      if (needsCheckIn) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'A reflection picked for how you\'re feeling right now.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF8A6F5C),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: onCheckIn,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB5651D),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Check in with yourself'),
                ),
              ],
            ),
          ),
        );
      }
      // Nothing picked and nothing to prompt for -- callers should
      // route this case to LockedPlaceholder instead (see HomeScreen),
      // but fall back to a quiet message rather than render nothing.
      return const Center(
        child: Text(
          'Nothing to show yet.',
          style: TextStyle(color: Color(0xFF8A6F5C)),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: FadeTransition(
                    opacity: fadeAnimation,
                    child: FavoritableReflection(
                      reflectionId: current.id,
                      text: current.text,
                      isFavorite: favoriteIds.contains(current.id),
                      onToggleFavorite: onToggleFavorite,
                    ),
                  ),
                ),
              ),
              if (!isReadOnly)
                Positioned(
                  top: 4,
                  right: 4,
                  child: IconButton(
                    onPressed: canReroll ? onReroll : null,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Show me another',
                    color: const Color(0xFF8A6F5C),
                    disabledColor: const Color(0xFFD8C3AE),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: TextButton.icon(
            onPressed: onExplore,
            icon: const Icon(Icons.shuffle, size: 18),
            label: const Text('See other reflections'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF8A6F5C),
            ),
          ),
        ),
      ],
    );
  }
}