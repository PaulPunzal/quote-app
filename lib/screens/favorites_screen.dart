import 'package:flutter/material.dart';
import '../models/embedded_reflection.dart';
import '../services/reflection_embedding_service.dart';
import '../services/favorites_service.dart';

/// Lists every reflection the user has favorited. Un-favoriting a
/// reflection here (via the heart button or double-tap) removes it
/// from the list immediately, same as it would anywhere else in the
/// app — favoriting behaves identically no matter where it's toggled
/// from, since it's all backed by the same [FavoritesService].
class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final ReflectionEmbeddingService _embeddingService =
      ReflectionEmbeddingService();
  final FavoritesService _favoritesService = FavoritesService();

  List<EmbeddedReflection> _favorites = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _embeddingService.allReflections();
    final favoriteIds = await _favoritesService.getAll();

    if (!mounted) return;
    setState(() {
      _favorites = all.where((r) => favoriteIds.contains(r.id)).toList();
      _loading = false;
    });
  }

  Future<void> _toggleFavorite(String id) async {
    await _favoritesService.toggle(id);
    if (!mounted) return;
    // Un-favoriting here means it no longer belongs in this list.
    setState(() {
      _favorites = _favorites.where((r) => r.id != id).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9),
      appBar: AppBar(
        title: const Text('Favorites'),
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _favorites.isEmpty
              ? _buildEmptyState()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 24),
                  itemCount: _favorites.length,
                  separatorBuilder: (_, __) => const Divider(height: 48),
                  itemBuilder: (context, index) {
                    final r = _favorites[index];
                    return _FavoritableReflection(
                      reflectionId: r.id,
                      text: r.text,
                      fontSize: 18,
                      isFavorite: true,
                      onToggleFavorite: _toggleFavorite,
                    );
                  },
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.favorite_border,
                size: 28, color: Color(0xFFD8C3AE)),
            const SizedBox(height: 16),
            const Text(
              'No favorites yet',
              style: TextStyle(
                fontSize: 15,
                fontStyle: FontStyle.italic,
                fontFamily: 'Georgia',
                color: Color(0xFF3B2E28),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Double-tap a reflection to save it here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFF8A6F5C)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Displays a reflection with a heart button and double-tap-to-favorite.
/// Private to this file — HomeScreen keeps its own copy since the two
/// screens don't otherwise share code.
class _FavoritableReflection extends StatefulWidget {
  final String reflectionId;
  final String text;
  final double fontSize;
  final bool isFavorite;
  final ValueChanged<String> onToggleFavorite;

  const _FavoritableReflection({
    required this.reflectionId,
    required this.text,
    required this.isFavorite,
    required this.onToggleFavorite,
    this.fontSize = 22,
  });

  @override
  State<_FavoritableReflection> createState() =>
      _FavoritableReflectionState();
}

class _FavoritableReflectionState extends State<_FavoritableReflection>
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
              if (widget.isFavorite) ...[
                const SizedBox(height: 18),
                const Icon(
                  Icons.favorite,
                  size: 18,
                  color: Color(0xFFB5651D),
                ),
              ],
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