import 'dart:math';
import 'package:flutter/material.dart';
import '../../models/embedded_reflection.dart';
import '../../services/reflection_daily_service.dart';
import '../../services/reflection_embedding_service.dart';
import '../../services/notification_service.dart';
import '../../services/favorites_service.dart';
import '../../services/weather_service.dart';
import '../../widgets/mood_check_in_sheet.dart';
import '../browse_screen.dart';
import '../favorites_screen.dart';
import 'widgets/explore_view.dart';
import 'widgets/locked_placeholder.dart';
import 'widgets/reflection_slot_view.dart';
import 'widgets/weather_strip.dart';

/// The main screen -- one body, no tabs. Which slot is "current" is
/// computed purely from the clock (see [_resolveCurrentSlot]):
///
///   - Before 5am: shows yesterday's already-finished Evening
///     reflection, read-only (decision 6) -- no new check-in, no
///     reroll. If there's no prior Evening pick at all (first-ever
///     launch before 5am), falls back to the old locked placeholder.
///   - 5am-5pm: Morning is current.
///   - After 5pm: Evening is current, replacing whatever was on
///     screen (Morning's own pick for the day is untouched in
///     storage, just no longer displayed).
///
/// Reopening the app within an already-picked slot's window shows
/// that pick with no re-prompt (decision 7). Only a manual reroll
/// re-touches the mood check-in; Explore reuses whatever context
/// (mood-ranked or random) produced the currently-shown reflection
/// without asking again (decision 4).
///
/// This replaces the old 3-tab (Morning / Check-in / Evening) design.
/// Both slots are now picked identically -- see
/// `ReflectionDailyService` -- so there's no structural reason left
/// for separate tab widgets; `ReflectionSlotView` covers every state a
/// single slot can be in.
///
/// Weather Location and History used to be separate icon buttons on
/// this screen's app bar. They now live inside the "All Reflections"
/// (Browse) screen instead, reached via the same book icon -- this
/// app bar only exposes Favorites and Browse now.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final ReflectionDailyService _dailyService = ReflectionDailyService();
  final ReflectionEmbeddingService _embeddingService =
      ReflectionEmbeddingService();
  final NotificationService _notifications = NotificationService();
  final FavoritesService _favoritesService = FavoritesService();
  final WeatherService _weatherService = WeatherService();

  /// Null only in the pre-5am carryover view -- there is no "current"
  /// Morning/Evening slot at that point, just a read-only look back at
  /// last night.
  ReflectionSlot? _currentSlot;

  EmbeddedReflection? _currentReflection;
  bool _loading = true;

  /// True only for the pre-5am carryover view (decision 6). Disables
  /// reroll and the check-in prompt -- browsing (Explore) still works.
  bool _isReadOnlyCarryover = false;

  /// True when [_currentSlot] hasn't been picked yet today and isn't
  /// read-only -- the slot view shows a "Check in with yourself" CTA
  /// instead of a reflection.
  bool _needsCheckIn = false;

  /// The moodId that produced [_currentReflection], IF this session
  /// is the one that picked it. Null means either "picked randomly"
  /// or "picked in an earlier session, context unknown" -- Explore
  /// treats both the same way: no similarity signal to build a
  /// "similar" band from, so it falls back to a full random shuffle
  /// (decision 4's stated fallback, now also covering the
  /// resumed-session case).
  String? _currentMoodId;

  /// The weatherId used for whichever pick informed
  /// [_currentReflection] this session -- reused (not re-fetched) if
  /// Explore needs to rebuild the same context vector for a similar
  /// band.
  String? _currentWeatherIdUsed;

  bool _canReroll = true;
  static const Duration _rerollCooldown = Duration(seconds: 3);

  Set<String> _favoriteIds = {};

  /// Kept purely for the WeatherStrip label -- matching itself always
  /// reads fresh from WeatherService when a pick actually happens.
  WeatherSnapshot? _weatherSnapshot;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  // --- Explore mode state (structurally unchanged from before) ---
  bool _exploring = false;
  final PageController _pageController = PageController();
  List<EmbeddedReflection> _explorePool = [];
  Set<String> _similarBandIds = {};

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
    WidgetsBinding.instance.addObserver(this);

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
        if (status != AnimationStatus.completed || !mounted) return;

        setState(() {
          _canAdvance = true;
          _readIndices.add(_currentExploreIndex);
        });

        if (_currentExploreIndex < _explorePool.length) {
          final currentId = _explorePool[_currentExploreIndex].id;
          if (_similarBandIds.contains(currentId)) {
            _dailyService.markHeadlineRotationUsed(currentId);
          }
        }
      });

    _load();
    _loadFavorites();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fadeController.dispose();
    _readController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// Recomputes the current slot on resume, so leaving the app
  /// backgrounded across a slot boundary (e.g. open at 4:58pm, reopen
  /// at 5:05pm) picks it up without needing a fresh cold start.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
      _refreshWeatherSnapshot();
    }
  }

  // ---------------------------------------------------------------------
  // Slot resolution + loading
  // ---------------------------------------------------------------------

  /// Pure function of the clock -- see class doc for the exact
  /// boundaries. Null means "pre-5am carryover," not a real slot.
  ReflectionSlot? _resolveCurrentSlot() {
    final hour = DateTime.now().hour;
    if (hour < 5) return null;
    return hour < 17 ? ReflectionSlot.morning : ReflectionSlot.evening;
  }

  static String _dateToString(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  Future<void> _load() async {
    final slot = _resolveCurrentSlot();
    if (slot == null) {
      await _loadYesterdayEveningCarryover();
    } else {
      await _loadCurrentSlot(slot);
    }
    _scheduleTomorrowNotification();
  }

  Future<void> _loadYesterdayEveningCarryover() async {
    setState(() {
      _loading = true;
      _isReadOnlyCarryover = true;
      _currentSlot = null;
      _needsCheckIn = false;
    });

    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final reflection = await _dailyService.getSlotForDate(
      ReflectionSlot.evening,
      _dateToString(yesterday),
    );

    if (!mounted) return;
    setState(() {
      _currentReflection = reflection;
      // Context from a prior day/session is never assumed known -- see
      // _currentMoodId doc.
      _currentMoodId = null;
      _currentWeatherIdUsed = null;
      _loading = false;
    });

    if (reflection != null) _revealWithFade();
  }

  Future<void> _loadCurrentSlot(ReflectionSlot slot) async {
    setState(() {
      _loading = true;
      _isReadOnlyCarryover = false;
      _currentSlot = slot;
    });

    final existing = await _dailyService.getSlotIfAssigned(slot);
    if (existing != null) {
      if (!mounted) return;
      setState(() {
        _currentReflection = existing;
        _needsCheckIn = false;
        _loading = false;
        // Unknown whether this session or an earlier one picked it --
        // treat as unknown/random for Explore's purposes (see field
        // doc on _currentMoodId).
        _currentMoodId = null;
        _currentWeatherIdUsed = null;
      });
      _revealWithFade();
      return;
    }

    if (!mounted) return;
    setState(() {
      _currentReflection = null;
      _needsCheckIn = true;
      _loading = false;
    });
  }

  Future<void> _revealWithFade() async {
    _fadeController.stop();
    _fadeController.value = 0;
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) _fadeController.forward();
  }

  Future<void> _refreshWeatherSnapshot() async {
    final snapshot = await _weatherService.currentSnapshot();
    if (mounted) setState(() => _weatherSnapshot = snapshot);
  }

  /// Fetches current weather (or falls back to the last cached
  /// reading) and updates [_weatherSnapshot] for the WeatherStrip
  /// label. Returns null if no location is configured, or neither a
  /// fresh nor cached reading is available.
  Future<String?> _currentWeatherId() async {
    final snapshot = await _weatherService.currentSnapshot();
    if (mounted) setState(() => _weatherSnapshot = snapshot);
    return snapshot?.conditionId;
  }

  Future<void> _scheduleTomorrowNotification() async {
    await _notifications.init();
    await _notifications.scheduleTomorrowGeneric(hour: 8, minute: 0);
  }

  // ---------------------------------------------------------------------
  // Check-in + picking
  // ---------------------------------------------------------------------

  /// Shows the mood check-in sheet and, based on the result, either
  /// picks/rerolls [slot] or leaves it untouched. This is the ONLY
  /// place mood gets (re-)asked -- Explore never triggers this (see
  /// class doc, decision 4).
  Future<void> _promptAndPick(ReflectionSlot slot,
      {bool forceReroll = false}) async {
    final result = await MoodCheckInSheet.show(context);
    switch (result) {
      case MoodPicked(:final moodId):
        await _pickForSlot(slot, moodId: moodId, forceReroll: forceReroll);
      case MoodSkipped():
        await _pickForSlot(slot, moodId: null, forceReroll: forceReroll);
      case MoodCancelled():
        // Leave the slot exactly as it was -- still needs check-in if
        // it did before, still showing the same reflection if it did.
        return;
    }
  }

  Future<void> _pickForSlot(
    ReflectionSlot slot, {
    required String? moodId,
    bool forceReroll = false,
  }) async {
    setState(() => _loading = true);
    final weatherId = await _currentWeatherId();

    final reflection = forceReroll
        ? await _dailyService.rerollSlot(
            slot: slot,
            moodId: moodId,
            weatherId: weatherId,
          )
        : await _dailyService.getSlotReflection(
            slot: slot,
            moodId: moodId,
            weatherId: weatherId,
          );

    if (!mounted) return;
    setState(() {
      _currentReflection = reflection;
      _currentMoodId = moodId;
      _currentWeatherIdUsed = weatherId;
      _needsCheckIn = false;
      _loading = false;
    });
    _revealWithFade();
  }

  /// Manual reroll of the current slot. Always re-prompts mood
  /// (decision 7) -- rerolling is a deliberate "not this one," and the
  /// person's mood may have genuinely changed since the original pick.
  Future<void> _reroll() async {
    if (!_canReroll || _isReadOnlyCarryover || _currentSlot == null) return;
    setState(() => _canReroll = false);

    await _promptAndPick(_currentSlot!, forceReroll: true);

    Future.delayed(_rerollCooldown, () {
      if (mounted) setState(() => _canReroll = true);
    });
  }

  Future<void> _checkIn() async {
    if (_currentSlot == null) return;
    await _promptAndPick(_currentSlot!);
  }

  // ---------------------------------------------------------------------
  // Favorites / navigation
  // ---------------------------------------------------------------------

  Future<void> _loadFavorites() async {
    final ids = await _favoritesService.getAll();
    if (mounted) setState(() => _favoriteIds = ids);
  }

  Future<void> _toggleFavorite(String id) async {
    final updated = await _favoritesService.toggle(id);
    if (!mounted) return;
    setState(() => _favoriteIds = updated);
  }

  Future<void> _openFavorites() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FavoritesScreen()),
    );
    await _loadFavorites();
  }

  /// Opens the Browse ("All Reflections") screen, which now also hosts
  /// navigation to Weather Location and History -- both used to be
  /// separate icon buttons on this app bar. Refresh weather snapshot
  /// and favorites on return, since either could have changed while
  /// there (a location change affects the next weather fetch; History
  /// and Favorites both allow un/favoriting).
  Future<void> _openBrowse() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BrowseScreen()),
    );
    await _refreshWeatherSnapshot();
    await _loadFavorites();
  }

  // ---------------------------------------------------------------------
  // Explore
  // ---------------------------------------------------------------------

  /// Enters Explore. Branches on whether the currently-shown
  /// reflection came from a mood-ranked pick this session
  /// ([_currentMoodId] non-null) or not (decision 4):
  ///   - Mood-ranked: rebuild the same context vector, offer a small
  ///     "similar to this" band up front, then the shuffled remainder.
  ///   - Random / unknown context: no similarity signal to build a
  ///     band from -- fully random shuffle over everything else.
  ///
  /// Either way, today's Morning AND Evening picks are excluded (not
  /// just whichever is currently displayed) along with the whole
  /// current headline-rotation-used set, same as before this refactor.
  Future<void> _enterExplore() async {
    final todayMorning =
        await _dailyService.getSlotIfAssigned(ReflectionSlot.morning);
    final todayEvening =
        await _dailyService.getSlotIfAssigned(ReflectionSlot.evening);
    final rotationUsed = await _dailyService.getHeadlineRotationUsedIds();

    final excludeIds = <String>{
      if (todayMorning != null) todayMorning.id,
      if (todayEvening != null) todayEvening.id,
      ...rotationUsed,
    };

    List<EmbeddedReflection> pool;
    Set<String> similarBandIds = {};

    if (_currentReflection != null && _currentMoodId != null) {
      final contextVector = await _embeddingService.buildContextVector(
        moodId: _currentMoodId,
        weatherId: _currentWeatherIdUsed,
        timeId:
            ReflectionDailyService.timeBucketIdForHour(DateTime.now().hour),
        moodWeight: 2.0,
        weatherWeight: 0.4,
        timeWeight: 0.6,
      );
      final ranked =
          await _embeddingService.rank(contextVector, excludeIds: excludeIds);

      final similar = _embeddingService
          .similarBand(ranked, minPoolSize: 3, maxPoolSize: 3)
          .map((s) => s.reflection)
          .toList()
        ..shuffle();
      similarBandIds = similar.map((r) => r.id).toSet();

      final remainder = ranked
          .where((s) => !similarBandIds.contains(s.reflection.id))
          .map((s) => s.reflection)
          .toList()
        ..shuffle();

      pool = [...similar, ...remainder];
    } else {
      final all = await _embeddingService.allReflections();
      pool = all.where((r) => !excludeIds.contains(r.id)).toList()..shuffle();
    }

    if (!mounted) return;
    setState(() {
      _explorePool = pool;
      _similarBandIds = similarBandIds;
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

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
        title: const Text('Daily Reflection'),
        actions: [
          IconButton(
            icon: const Icon(Icons.favorite_border),
            tooltip: 'Favorites',
            onPressed: _openFavorites,
          ),
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: 'Browse all quotes',
            onPressed: _openBrowse,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!_exploring && !_isReadOnlyCarryover) _buildSlotLabel(),
            if (!_exploring && _weatherSnapshot != null && !_isReadOnlyCarryover)
              WeatherStrip(snapshot: _weatherSnapshot!),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _exploring ? _buildExploreView() : _buildSlotBody(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Small caption making it clear which slot is showing, now that
  /// there's no tab bar doing that job implicitly.
  Widget _buildSlotLabel() {
    final label = _currentSlot == ReflectionSlot.morning ? 'Good Morning' : 'Good Evening';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xFF8A6F5C),
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  Widget _buildSlotBody() {
    // Rare case: pre-5am with no prior Evening pick ever recorded
    // (first-ever launch before 5am). Nothing to carry over and
    // nothing to check in for yet -- fall back to the old locked
    // placeholder rather than an empty screen.
    if (_isReadOnlyCarryover && _currentReflection == null && !_loading) {
      return LockedPlaceholder(
        key: const ValueKey('locked'),
        label: 'evening',
        hint: 'Come back after 5:00 PM',
        icon: Icons.nights_stay_outlined,
        onExplore: _enterExplore,
      );
    }

    return ReflectionSlotView(
      key: const ValueKey('slot'),
      reflection: _currentReflection,
      loading: _loading,
      needsCheckIn: _needsCheckIn,
      isReadOnly: _isReadOnlyCarryover,
      fadeAnimation: _fadeAnimation,
      favoriteIds: _favoriteIds,
      onToggleFavorite: _toggleFavorite,
      onCheckIn: _checkIn,
      onReroll: _reroll,
      canReroll: _canReroll,
      onExplore: _enterExplore,
    );
  }

  Widget _buildExploreView() {
    return ExploreView(
      key: const ValueKey('explore'),
      pool: _explorePool,
      pageController: _pageController,
      readController: _readController,
      canAdvance: _canAdvance,
      prompt: _currentPrompt,
      favoriteIds: _favoriteIds,
      onToggleFavorite: _toggleFavorite,
      onPageChanged: _startReadCooldown,
      onExit: _exitExplore,
    );
  }
}