import 'package:flutter/material.dart';
import '../../../models/embedded_reflection.dart';
import 'favoritable_reflection.dart';
import 'locked_placeholder.dart';
import 'quiet_loading_dot.dart';

/// One of the Morning/Evening tabs: a single ambient reflection, locked
/// until its time-of-day window opens, with a way to jump into Explore.
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
          child: Center(
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
