import 'package:flutter/material.dart';
import '../../../models/embedded_reflection.dart';
import 'favoritable_reflection.dart';

/// Full-bleed shuffle-through-everything mode, reachable from any tab.
/// Each reflection has a short read-cooldown (driven by [readController],
/// owned by the parent) before swiping to the next one is allowed.
class ExploreView extends StatelessWidget {
  final List<EmbeddedReflection> pool;
  final PageController pageController;
  final AnimationController readController;
  final bool canAdvance;
  final String prompt;
  final Set<String> favoriteIds;
  final ValueChanged<String> onToggleFavorite;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onExit;

  const ExploreView({
    super.key,
    required this.pool,
    required this.pageController,
    required this.readController,
    required this.canAdvance,
    required this.prompt,
    required this.favoriteIds,
    required this.onToggleFavorite,
    required this.onPageChanged,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('explore'),
      children: [
        Expanded(
          child: pool.isEmpty
              ? const Center(child: Text('No other reflections yet.'))
              : PageView.builder(
                  controller: pageController,
                  onPageChanged: onPageChanged,
                  physics: canAdvance
                      ? const PageScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  // Finite and non-looping: pool is a handful of
                  // similar reflections followed by the shuffled rest
                  // of the corpus (see HomeScreen._enterExplore), so
                  // there's plenty to swipe through without ever
                  // repeating.
                  itemCount: pool.length,
                  itemBuilder: (context, index) {
                    final r = pool[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Center(
                        child: FavoritableReflection(
                          reflectionId: r.id,
                          text: r.text,
                          fontSize: 20,
                          isFavorite: favoriteIds.contains(r.id),
                          onToggleFavorite: onToggleFavorite,
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: AnimatedBuilder(
              animation: readController,
              builder: (context, _) => LinearProgressIndicator(
                value: readController.value,
                minHeight: 3,
                backgroundColor: const Color(0xFFF0E4D4),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFFD8C3AE),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          // NOTE: now actually shows the rotating [prompt] text instead
          // of a single hardcoded string — the original had a
          // `_currentPrompt` field that was computed but never
          // displayed. Small bonus fix while this file was already
          // being split apart.
          child: Text(
            canAdvance ? 'Swipe for another' : prompt,
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A6F5C)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextButton(
            onPressed: onExit,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF8A6F5C),
            ),
            child: const Text('Back to today'),
          ),
        ),
      ],
    );
  }
}