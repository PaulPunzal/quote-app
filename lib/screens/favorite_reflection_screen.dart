import 'package:flutter/material.dart';

/// Displays a reflection with a heart button and double-tap-to-favorite.
/// Used everywhere a reflection is shown — Home's ambient/on-demand
/// tabs, Explore, and the Favorites screen — so favoriting looks and
/// behaves the same no matter where you found the reflection.
class FavoritableReflection extends StatefulWidget {
  final String reflectionId;
  final String text;
  final double fontSize;
  final bool isFavorite;
  final ValueChanged<String> onToggleFavorite;

  const FavoritableReflection({
    super.key,
    required this.reflectionId,
    required this.text,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.fontSize = 22,
  });

  @override
  State<FavoritableReflection> createState() => _FavoritableReflectionState();
}

class _FavoritableReflectionState extends State<FavoritableReflection>
    with SingleTickerProviderStateMixin {
  late final AnimationController _popController;
  late final Animation<double> _popScale;
  late final Animation<double> _popOpacity;

  @override
  void initState() {
    super.initState();
    _popController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    _popScale = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.5, end: 1.15)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 45,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.15, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 55,
      ),
    ]).animate(_popController);
    _popOpacity = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 15),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 45),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 40),
    ]).animate(_popController);
  }

  @override
  void dispose() {
    _popController.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    final wasFavorite = widget.isFavorite;
    widget.onToggleFavorite(widget.reflectionId);
    // Only pop the big heart when *becoming* favorited — double-tapping
    // an already-favorited one to remove it doesn't need the flourish.
    if (!wasFavorite) {
      _popController.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: _handleDoubleTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: widget.fontSize,
                  fontStyle: FontStyle.italic,
                  height: 1.5,
                  color: const Color(0xFF3B2E28),
                  fontFamily: 'Georgia',
                ),
              ),
              const SizedBox(height: 18),
              IconButton(
                onPressed: () =>
                    widget.onToggleFavorite(widget.reflectionId),
                icon: Icon(
                  widget.isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: widget.isFavorite
                      ? const Color(0xFFB5651D)
                      : const Color(0xFF8A6F5C),
                ),
                tooltip: widget.isFavorite
                    ? 'Remove from favorites'
                    : 'Add to favorites',
              ),
            ],
          ),
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _popController,
              builder: (context, _) {
                if (_popController.isDismissed) {
                  return const SizedBox.shrink();
                }
                return Opacity(
                  opacity: _popOpacity.value,
                  child: Transform.scale(
                    scale: _popScale.value,
                    child: const Icon(
                      Icons.favorite,
                      size: 72,
                      color: Color(0xFFB5651D),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}