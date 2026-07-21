import 'dart:math';
import 'package:flutter/material.dart';
import '../models/embedded_reflection.dart';
import '../services/reflection_daily_service.dart';
import '../services/reflection_embedding_service.dart';
import '../services/notification_service.dart';
import '../services/favorites_service.dart';
import '../widgets/mood_check_in_sheet.dart';
import 'browse_screen.dart';

/// The main screen — three tabs:
///   - Morning / Evening: ambient picks, auto-assigned on load from
///     weather + a fixed time-of-day context (not the current clock —
///     see ReflectionDailyService.getSlotReflection's `timeId` doc).
///     Fixed for the day once picked, same as the old single-reflection
///     behavior.
///   - Check in: the old mood-check-in flow, now explicitly triggered
///     by a button rather than blocking the screen on load. Supports
///     "Something else" to re-roll (re-asking mood) instead of being
///     stuck with one pick for the whole day.
///
/// Explore mode (shuffle through everything) is unchanged conceptually,
/// just reachable from any tab instead of being tied to one reflection.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  final ReflectionDailyService _dailyService = ReflectionDailyService();
  final ReflectionEmbeddingService _embeddingService =
      ReflectionEmbeddingService();
  final NotificationService _notifications = NotificationService();
  final FavoritesService _favoritesService = FavoritesService();

  late final TabController _tabController;

  EmbeddedReflection? _morning;
  EmbeddedReflection? _evening;
  EmbeddedReflection? _onDemand;

  bool _loadingAmbient = true;
  bool _onDemandLoading = false;

  Set<String> _favoriteIds = {};

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  // --- Explore mode state (unchanged from before) ---
  bool _exploring = false;
  final PageController _pageController = PageController();
  List<EmbeddedReflection> _explorePool = [];

  static const Duration _readCooldown = Duration(seconds: 3);
  late final AnimationController _readController;
  bool _canAdvance = false;
  int _currentExploreIndex = 0;
  final Set<int> _readIndices = {};
  final _random = Random();

  static const List<String> _readPrompts = [
    'Take your time.',
    'Read it slowly.',
    'No rush here.',
    'Let it sink in.',
    'Stay with it.',
    'Breathe, then read.',
  ];
  String _currentPrompt = _readPrompts.first;

  @override
  void initState() {
    super.initState();

    // Default tab follows the clock so the app still feels timely on
    // open. Before 5am neither ambient tab is unlocked yet (see
    // _isMorningUnlocked/_isEveningUnlocked below), so land on Check In
    // instead of a locked tab.
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: _initialTabIndex(),
    );

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );

    _readController = AnimationController(
      vsync: this,
      duration: _readCooldown,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() {
            _canAdvance = true;
            _readIndices.add(_currentExploreIndex);
          });
        }
      });

    _loadAmbientReflections();
    _loadExistingOnDemand();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final ids = await _favoritesService.getAll();
    if (mounted) setState(() => _favoriteIds = ids);
  }

  /// Flips [id]'s favorited state and updates local state so every tab
  /// showing that reflection re-renders its heart immediately.
  Future<void> _toggleFavorite(String id) async {
    final updated = await _favoritesService.toggle(id);
    if (!mounted) return;
    setState(() => _favoriteIds = updated);
  }

  int _initialTabIndex() {
    final hour = DateTime.now().hour;
    if (hour < 5) return 1; // both ambient tabs locked — land on Check In
    return hour < 17 ? 0 : 2;
  }

  /// Morning unlocks at 5am and stays visible the rest of the day —
  /// once morning has actually happened there's nothing left to spoil.
  bool get _isMorningUnlocked => DateTime.now().hour >= 5;

  /// Evening unlocks at 5pm, same reasoning. Both flip back to locked
  /// at midnight because a fresh date means a fresh (not-yet-picked-
  /// for-real) slot, even though the reflection itself is pre-picked
  /// silently the moment the tab is opened.
  bool get _isEveningUnlocked => DateTime.now().hour >= 17;

  /// TODO(weather): stubbed for now — always returns null, so matching
  /// runs on time (and, for the check-in tab, mood) only. Once a
  /// weather source is wired in, map its condition to one of the
  /// 'weather_*' ids from context_options.json and return that instead.
  Future<String?> _currentWeatherId() async {
    return null;
  }

  /// Picks (or loads today's already-picked) morning and evening
  /// reflections. No mood check-in involved — these are ambient, not
  /// asked-for.
  Future<void> _loadAmbientReflections() async {
    final weatherId = await _currentWeatherId();

    final morning = await _dailyService.getSlotReflection(
      slot: ReflectionSlot.morning,
      weatherId: weatherId,
      timeId: 'time_morning',
    );
    final evening = await _dailyService.getSlotReflection(
      slot: ReflectionSlot.evening,
      weatherId: weatherId,
      timeId: 'time_evening',
    );

    if (!mounted) return;
    setState(() {
      _morning = morning;
      _evening = evening;
      _loadingAmbient = false;
    });

    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) _fadeController.forward();

    _scheduleTomorrowNotification();
  }

  /// If the on-demand slot was already picked earlier today (e.g.
  /// reopening the app), show it without prompting for mood again.
  Future<void> _loadExistingOnDemand() async {
    final existing =
        await _dailyService.getSlotIfAssigned(ReflectionSlot.onDemand);
    if (existing != null && mounted) {
      setState(() => _onDemand = existing);
    }
  }

  Future<void> _scheduleTomorrowNotification() async {
    await _notifications.init();
    await _notifications.scheduleTomorrowGeneric(
      hour: 8,
      minute: 0,
    );
  }

  /// Shows the mood check-in sheet and (re-)picks the on-demand
  /// reflection. Always force-rerolls: on first check-in today the
  /// cache is empty anyway, and on a repeat check-in ("Something
  /// else") the person's mood may have changed, so re-asking and
  /// always picking fresh is simpler and more honest than reusing a
  /// stale answer.
  Future<void> _checkIn() async {
    final moodId = await MoodCheckInSheet.show(context);
    if (moodId == null) return; // sheet dismissed without a choice

    setState(() => _onDemandLoading = true);
    final weatherId = await _currentWeatherId();
    final reflection = await _dailyService.rerollSlot(
      slot: ReflectionSlot.onDemand,
      moodId: moodId,
      weatherId: weatherId,
    );

    if (!mounted) return;
    setState(() {
      _onDemand = reflection;
      _onDemandLoading = false;
    });
  }

  Future<void> _enterExplore() async {
    final all = await _embeddingService.allReflections();
    final shuffled = List<EmbeddedReflection>.from(all)..shuffle();

    if (!mounted) return;
    setState(() {
      _explorePool = shuffled;
      _exploring = true;
      _currentExploreIndex = 0;
      _readIndices.clear();
    });
    _startReadCooldown(0);
  }

  void _exitExplore() {
    setState(() => _exploring = false);
  }

  void _startReadCooldown(int index) {
    _currentExploreIndex = index;

    if (_readIndices.contains(index)) {
      setState(() => _canAdvance = true);
      _readController.value = 1;
      return;
    }

    setState(() {
      _canAdvance = false;
      _currentPrompt = _readPrompts[_random.nextInt(_readPrompts.length)];
    });
    _readController
      ..stop()
      ..value = 0
      ..forward();
  }

  void _openBrowse() {
    // NOTE: still browses the legacy tagged Quote pool, not the
    // embedded reflections — same pre-existing gap as before, not
    // something this change touches.
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BrowseScreen()),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _fadeController.dispose();
    _readController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
        title: const Text('Daily Reflection'),
        bottom: _exploring
            ? null
            : TabBar(
                controller: _tabController,
                labelColor: const Color(0xFF3B2E28),
                unselectedLabelColor: const Color(0xFF8A6F5C),
                indicatorColor: const Color(0xFFB5651D),
                tabs: const [
                  Tab(text: 'Morning'),
                  Tab(text: 'Check in'),
                  Tab(text: 'Evening'),
                ],
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: 'Browse all quotes',
            onPressed: _openBrowse,
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _exploring ? _buildExploreView() : _buildTabs(),
        ),
      ),
    );
  }

  Widget _buildTabs() {
    return TabBarView(
      key: const ValueKey('tabs'),
      controller: _tabController,
      children: [
        _buildAmbientTab(
          _morning,
          unlocked: _isMorningUnlocked,
          lockedLabel: 'morning',
          lockedHint: 'Come back after 5:00 AM',
          lockedIcon: Icons.wb_twilight,
        ),
        _buildOnDemandTab(),
        _buildAmbientTab(
          _evening,
          unlocked: _isEveningUnlocked,
          lockedLabel: 'evening',
          lockedHint: 'Come back after 5:00 PM',
          lockedIcon: Icons.nights_stay_outlined,
        ),
      ],
    );
  }

  Widget _buildAmbientTab(
    EmbeddedReflection? reflection, {
    required bool unlocked,
    required String lockedLabel,
    required String lockedHint,
    required IconData lockedIcon,
  }) {
    if (_loadingAmbient || reflection == null) {
      return const Center(child: _QuietLoadingDot());
    }

    if (!unlocked) {
      return _buildLockedPlaceholder(
        label: lockedLabel,
        hint: lockedHint,
        icon: lockedIcon,
      );
    }

    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: _FavoritableReflection(
                  reflectionId: reflection.id,
                  text: reflection.text,
                  isFavorite: _favoriteIds.contains(reflection.id),
                  onToggleFavorite: _toggleFavorite,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: TextButton.icon(
            onPressed: _enterExplore,
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

  Widget _buildLockedPlaceholder({
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: const Color(0xFFD8C3AE)),
            const SizedBox(height: 16),
            Text(
              'Your $label reflection is waiting',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontStyle: FontStyle.italic,
                fontFamily: 'Georgia',
                color: Color(0xFF3B2E28),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A6F5C)),
            ),
            const SizedBox(height: 20),
            TextButton(
              onPressed: _enterExplore,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF8A6F5C),
              ),
              child: const Text('Explore reflections instead'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOnDemandTab() {
    if (_onDemandLoading) {
      return const Center(child: _QuietLoadingDot());
    }

    if (_onDemand == null) {
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
                onPressed: _checkIn,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB5651D),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
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
              child: _FavoritableReflection(
                reflectionId: _onDemand!.id,
                text: _onDemand!.text,
                isFavorite: _favoriteIds.contains(_onDemand!.id),
                onToggleFavorite: _toggleFavorite,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: TextButton(
            onPressed: _checkIn,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF8A6F5C),
            ),
            child: const Text('Something else'),
          ),
        ),
      ],
    );
  }

  Widget _buildExploreView() {
    return Column(
      key: const ValueKey('explore'),
      children: [
        Expanded(
          child: _explorePool.isEmpty
              ? const Center(child: Text('No other reflections yet.'))
              : PageView.builder(
                  controller: _pageController,
                  onPageChanged: _startReadCooldown,
                  physics: _canAdvance
                      ? const PageScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  itemCount: _explorePool.length,
                  itemBuilder: (context, index) {
                    final r = _explorePool[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Center(
                        child: _FavoritableReflection(
                          reflectionId: r.id,
                          text: r.text,
                          fontSize: 20,
                          isFavorite: _favoriteIds.contains(r.id),
                          onToggleFavorite: _toggleFavorite,
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
              animation: _readController,
              builder: (context, _) => LinearProgressIndicator(
                value: _readController.value,
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
          child: Text(
            _canAdvance ? 'Swipe for another' : 'Take a moment…',
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A6F5C)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextButton(
            onPressed: _exitExplore,
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

/// Displays a reflection with a heart button and double-tap-to-favorite.
/// Used everywhere a reflection is shown — ambient tabs, on-demand, and
/// Explore — so favoriting works the same regardless of where you found
/// the reflection.
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

class _QuietLoadingDot extends StatelessWidget {
  const _QuietLoadingDot();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 8,
      height: 8,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xFFD8C3AE),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}