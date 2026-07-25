import 'package:flutter/material.dart';
import '../../../models/embedded_reflection.dart';
import 'favoritable_reflection.dart';
import 'locked_placeholder.dart';
import 'quiet_loading_dot.dart';

/// One of the Morning/Evening tabs: a single ambient reflection, locked
/// until its time-of-day window opens, with a way to reroll it, or
/// jump into Explore.
class AmbientTab extends StatelessWidget {
  final EmbeddedReflection? reflection;
  final bool loading;
  final bool unlocked;
  final String lockedLabel;
  final String lockedHint;
  final IconData lockedIcon;
  final Animation<double> fadeAnimation;
  final Set<String> favoriteIds;
  final ValueChanged<String> onToggleFavorite;
  final VoidCallback onExplore;
  final VoidCallback onReroll;
  final bool canReroll; // NEW: false during the post-reroll cooldown

  const AmbientTab({
    super.key,
    required this.reflection,
    required this.loading,
    required this.unlocked,
    required this.lockedLabel,
    required this.lockedHint,
    required this.lockedIcon,
    required this.fadeAnimation,
    required this.favoriteIds,
    required this.onToggleFavorite,
    required this.onExplore,
    required this.onReroll,
    required this.canReroll,
  });

  @override
  Widget build(BuildContext context) {
    if (loading || reflection == null) {
      return const Center(child: QuietLoadingDot());
    }

    if (!unlocked) {
      return LockedPlaceholder(
        label: lockedLabel,
        hint: lockedHint,
        icon: lockedIcon,
        onExplore: onExplore,
      );
    }

    final current = reflection!;

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