import 'package:flutter/material.dart';
import '../../../models/embedded_reflection.dart';
import 'favoritable_reflection.dart';
import 'quiet_loading_dot.dart';

/// The "Check in" tab: prompts for a mood check-in if nothing's been
/// picked yet today, otherwise shows the on-demand reflection with a
/// "Something else" reroll.
class OnDemandTab extends StatelessWidget {
  final EmbeddedReflection? reflection;
  final bool loading;
  final Set<String> favoriteIds;
  final ValueChanged<String> onToggleFavorite;
  final VoidCallback onCheckIn;

  const OnDemandTab({
    super.key,
    required this.reflection,
    required this.loading,
    required this.favoriteIds,
    required this.onToggleFavorite,
    required this.onCheckIn,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: QuietLoadingDot());
    }

    final current = reflection;
    if (current == null) {
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

    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: FavoritableReflection(
                reflectionId: current.id,
                text: current.text,
                isFavorite: favoriteIds.contains(current.id),
                onToggleFavorite: onToggleFavorite,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: TextButton(
            onPressed: onCheckIn,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF8A6F5C),
            ),
            child: const Text('Something else'),
          ),
        ),
      ],
    );
  }
}
