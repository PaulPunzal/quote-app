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
import '../history_screen.dart';
import '../weather_location_screen.dart';
import 'widgets/ambient_tab.dart';
import 'widgets/explore_view.dart';
import 'widgets/on_demand_tab.dart';
import 'widgets/weather_strip.dart';

/// The main screen — three tabs:
///   - Morning / Evening: ambient picks, auto-assigned from weather + a
///     fixed time-of-day context (not the current clock — see
///     ReflectionDailyService.getSlotReflection's `timeId` doc). Fixed
///     for the day once picked, but can be manually rerolled (subject
///     to a short per-tab cooldown) via the small refresh icon over the
///     reflection -- rerolling reuses that tab's already-fetched
///     weather reading rather than fetching fresh, since "not this one"
///     is a different intent than "conditions changed."
///
///     Morning is picked the moment the app is opened (whenever that
///     is). Evening is picked lazily — the first time the Evening tab
///     is actually viewed after 5pm — rather than at the same moment
///     as morning. That way each slot gets its own fresh weather
///     reading taken when it's actually needed, instead of both being
///     decided off a single weather fetch from whenever the app
///     happened to be opened that day (which could be hours before
///     evening even arrives).
///   - Check in: the old mood-check-in flow, now explicitly triggered
///     by a button rather than blocking the screen on load. Supports
///     "Something else" to re-roll (re-asking mood) instead of being
///     stuck with one pick for the whole day.
///
/// Explore mode (shuffle through everything) is unchanged conceptually,
/// just reachable from any tab instead of being tied to one reflection.
/// Because it's entered by reading whichever reflection is currently
/// assigned to that tab's state field, a manual reroll of Morning or
/// Evening is automatically reflected the next time Explore is entered
/// from that tab -- no extra plumbing needed.
///
/// This class owns all state and business logic; the actual tab/explore
/// bodies live in sibling files under widgets/ so this file doesn't have
/// to grow every time the UI gets a new piece.
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
  final WeatherService _weatherService = WeatherService();

  late final TabController _tabController;

  EmbeddedReflection? _morning;
  EmbeddedReflection? _evening;
  EmbeddedReflection? _onDemand;

  bool _loadingAmbient = true;

  /// Separate from [_loadingAmbient] because evening now loads on its
  /// own schedule (see class doc) — it can still be "not yet picked"
  /// well after morning has finished loading.
  bool _loadingEvening = true;

  bool _onDemandLoading = false;

  /// The weatherId actually used (or attempted) the moment each ambient
  /// slot's weather was fetched. Kept purely so "See other reflections"
  /// (and manual rerolls) can rank against the same weather+time
  /// context the currently-shown reflection was picked from, instead of
  /// re-fetching weather or ranking with no context at all.
  String? _morningWeatherId;
  String? _eveningWeatherId;

  /// Per-tab manual-reroll cooldown flags. False for [_rerollCooldown]
  /// after a reroll, to prevent rapid-fire tapping; independent per
  /// tab since morning/evening are separate contexts. This is purely a
  /// tap-rate limiter -- the actual "can't repeat the same reflection"
  /// guarantee lives in ReflectionDailyService's hard-exclude layer and
  /// applies regardless of how long you wait between rerolls.
  bool _canRerollMorning = true;
  bool _canRerollEvening = true;
  static const Duration _rerollCooldown = Duration(seconds: 3);

  Set<String> _favoriteIds = {};

  /// Most recent weather reading, kept around purely for the
  /// [WeatherStrip] label — the *matching* itself reads straight from
  /// SharedPreferences via WeatherService each time a slot is picked,
  /// so this field never gates anything.
  WeatherSnapshot? _weatherSnapshot;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  // --- Explore mode state ---
  bool _exploring = false;
  final PageController _pageController = PageController();
  List<EmbeddedReflection> _explorePool = [];

  /// Ids currently offered in Explore's "similar to this headline"
  /// band. Being included here doesn't cost a reflection its headline
  /// rotation turn on its own -- only actually reading it (read-
  /// cooldown completing while it's the current page) does. See the
  /// _readController status listener below.
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

    // Default tab follows the clock so the app still feels timely on
    // open. Before 5am neither ambient tab is unlocked yet (see
    // _isMorningUnlocked/_isEveningUnlocked below), so land on Check In
    // instead of a locked tab.
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: _initialTabIndex(),
    );
    // Evening's reflection is picked lazily (see class doc) — this
    // catches the case where the app is opened after 5pm and the user
    // switches back and forth into the Evening tab later in the same
    // session, or lands there via a tab change rather than at launch.
    _tabController.addListener(_onTabChanged);

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

        // Only counts as "used" once actually read (cooldown
        // completed while it's the current page), not merely offered
        // in the pool -- so scrolling straight past something in
        // Explore doesn't cost it its headline rotation turn.
        if (_currentExploreIndex < _explorePool.length) {
          final currentId = _explorePool[_currentExploreIndex].id;
          if (_similarBandIds.contains(currentId)) {
            _dailyService.markHeadlineRotationUsed(currentId);
          }
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

  /// Opens the Favorites list screen. Un-favoriting a reflection while
  /// there (or anywhere else) changes the same underlying storage, so
  /// we just reload [_favoriteIds] on return to stay in sync — no need
  /// to pass data back and forth manually.
  Future<void> _openFavorites() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FavoritesScreen()),
    );
    await _loadFavorites();
  }

  /// Opens the History screen (everything ever shown, by date/slot).
  /// Same reasoning as [_openFavorites] -- favoriting is possible from
  /// there too, so refresh local state on return.
  Future<void> _openHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HistoryScreen()),
    );
    await _loadFavorites();
  }

  /// Opens the weather location settings. A location change doesn't
  /// reroll anything already picked today (that would be jarring) — it
  /// just refreshes the label shown in the UI and takes effect on the
  /// next slot pick (tomorrow's ambient picks, or the next check-in).
  Future<void> _openWeatherSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WeatherLocationScreen()),
    );
    await _refreshWeatherSnapshot();
  }

  Future<void> _refreshWeatherSnapshot() async {
    final snapshot = await _weatherService.currentSnapshot();
    if (mounted) setState(() => _weatherSnapshot = snapshot);
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

  /// Called on every tab-controller change (fires while the swipe/tap
  /// animation is in flight, then again once it settles). We only act
  /// once it settles on the Evening tab, since that's the first
  /// reliable point to say "the user is actually looking at Evening
  /// now" — the right moment to fetch a fresh weather reading and pick
  /// evening's reflection if it hasn't been picked yet today.
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == 2 && _isEveningUnlocked && _evening == null) {
      _pickEveningReflection();
    }
  }

  /// Fetches current weather (online) or falls back to the last cached
  /// reading (offline) via WeatherService, mapping it to one of the
  /// 'weather_*' context ids. Also updates [_weatherSnapshot] so the UI
  /// can show what conditions actually informed the pick. Returns null
  /// if no location has been configured yet, or if there's neither a
  /// fresh reading nor a cached one to fall back to — matching runs on
  /// time (and mood, for the check-in tab) alone in that case, same as
  /// before this feature existed.
  Future<String?> _currentWeatherId() async {
    final snapshot = await _weatherService.currentSnapshot();
    if (mounted) setState(() => _weatherSnapshot = snapshot);
    return snapshot?.conditionId;
  }

  /// Picks (or loads today's already-picked) morning reflection using a
  /// weather reading fetched right now. Evening is handled separately
  /// by [_loadOrDeferEvening] so it doesn't share morning's (possibly
  /// hours-stale-by-evening) weather snapshot.
  Future<void> _loadAmbientReflections() async {
    final weatherId = await _currentWeatherId();
    _morningWeatherId = weatherId;

    final morning = await _dailyService.getSlotReflection(
      slot: ReflectionSlot.morning,
      weatherId: weatherId,
      timeId: 'time_morning',
    );

    if (!mounted) return;
    setState(() {
      _morning = morning;
      _loadingAmbient = false;
    });

    await _loadOrDeferEvening();

    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) _fadeController.forward();

    _scheduleTomorrowNotification();
  }

  /// Loads today's evening reflection if it's already been picked
  /// earlier (e.g. reopening the app later the same evening), picks it
  /// fresh right now if the app happened to be opened after 5pm and
  /// nothing's assigned yet for today, or otherwise leaves it unpicked
  /// so [_onTabChanged] can pick it — with a weather reading fetched at
  /// that moment — the first time the Evening tab is actually viewed
  /// after unlock.
  Future<void> _loadOrDeferEvening() async {
    final existingEvening =
        await _dailyService.getSlotIfAssigned(ReflectionSlot.evening);
    if (!mounted) return;

    if (existingEvening != null) {
      setState(() {
        _evening = existingEvening;
        _loadingEvening = false;
      });
    } else if (_isEveningUnlocked) {
      // App was opened after 5pm and evening hasn't been picked yet
      // today -- pick it now, with its own fresh weather reading.
      await _pickEveningReflection();
    } else {
      // Not evening yet -- nothing to load; AmbientTab will show the
      // locked placeholder until 5pm.
      setState(() => _loadingEvening = false);
    }
  }

  /// Fetches a fresh weather reading and picks (or loads, if some other
  /// caller beat us to it) today's evening reflection. Safe to call
  /// more than once -- the early return means only the first caller
  /// (whichever of [_loadOrDeferEvening] or [_onTabChanged] gets there
  /// first) actually does the work.
  Future<void> _pickEveningReflection() async {
    if (_evening != null) return;

    setState(() => _loadingEvening = true);
    final weatherId = await _currentWeatherId();
    _eveningWeatherId = weatherId;
    final evening = await _dailyService.getSlotReflection(
      slot: ReflectionSlot.evening,
      weatherId: weatherId,
      timeId: 'time_evening',
    );

    if (!mounted) return;
    setState(() {
      _evening = evening;
      _loadingEvening = false;
    });
  }

  /// Manually rerolls today's Morning reflection. Reuses
  /// [_morningWeatherId] (the weather reading already fetched for
  /// morning) rather than fetching fresh -- rerolling means "not this
  /// one," not "conditions changed since I opened the app." Guarded by
  /// [_canRerollMorning] so rapid taps are ignored; the underlying
  /// service-layer hard-exclude guarantees the just-shown reflection
  /// can't come back regardless of cooldown timing.
  Future<void> _rerollMorning() async {
    if (!_canRerollMorning) return;
    setState(() {
      _loadingAmbient = true;
      _canRerollMorning = false;
    });

    final rerolled = await _dailyService.rerollSlot(
      slot: ReflectionSlot.morning,
      weatherId: _morningWeatherId,
    );

    if (!mounted) return;
    setState(() {
      _morning = rerolled;
      _loadingAmbient = false;
    });

    Future.delayed(_rerollCooldown, () {
      if (mounted) setState(() => _canRerollMorning = true);
    });
  }

  /// Same idea as [_rerollMorning], for Evening.
  Future<void> _rerollEvening() async {
    if (!_canRerollEvening) return;
    setState(() {
      _loadingEvening = true;
      _canRerollEvening = false;
    });

    final rerolled = await _dailyService.rerollSlot(
      slot: ReflectionSlot.evening,
      weatherId: _eveningWeatherId,
    );

    if (!mounted) return;
    setState(() {
      _evening = rerolled;
      _loadingEvening = false;
    });

    Future.delayed(_rerollCooldown, () {
      if (mounted) setState(() => _canRerollEvening = true);
    });
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

  /// Enters Explore mode. When [contextTimeId] is given (i.e. entering
  /// from the Morning or Evening tab), the pool starts with a small
  /// handful of reflections genuinely close to the same weather+time
  /// context that picked the reflection currently shown on that tab --
  /// so the first few swipes feel like a continuation of that same
  /// ambient "mood" -- and then the rest of the corpus follows,
  /// shuffled, so there's always something new to swipe to without
  /// ever repeating (no looping back to the start).
  ///
  /// Because [_morning]/[_evening] are read here at call time, this
  /// always reflects whichever reflection is currently assigned to
  /// that tab -- including one that was just manually rerolled.
  ///
  /// [contextTimeId] is omitted only if Explore is ever entered without
  /// a specific ambient tab in mind, in which case it falls back to a
  /// fully random shuffle over everything (the old behavior).
  Future<void> _enterExplore({
    String? contextTimeId,
    String? contextWeatherId,
  }) async {
    List<EmbeddedReflection> pool;
    Set<String> similarBandIds = {};

    if (contextTimeId != null) {
      final contextVector = await _embeddingService.buildContextVector(
        weatherId: contextWeatherId,
        timeId: contextTimeId,
      );

      // Exclude BOTH today's literal headlines AND the full headline
      // rotation "used" set -- so a reflection that's already had its
      // headline turn this cycle can't even be offered in the similar
      // band, not just excluded from being re-picked outright.
      final rotationUsed = await _dailyService.getHeadlineRotationUsedIds();
      final excludeIds = <String>{
        if (_morning?.id != null) _morning!.id,
        if (_evening?.id != null) _evening!.id,
        ...rotationUsed,
      };
      final ranked = await _embeddingService.rank(
        contextVector,
        excludeIds: excludeIds,
      );

      // 3: a small taste of "close to this mood" up front.
      final similar = _embeddingService
          .similarBand(ranked, minPoolSize: 3, maxPoolSize: 3)
          .map((s) => s.reflection)
          .toList()
        ..shuffle();
      similarBandIds = similar.map((r) => r.id).toSet();

      // NOTE: being offered here is free -- only actually reading one
      // of these (read-cooldown completing while it's the current
      // page) marks it headline-rotation-used. See the _readController
      // status listener in initState.

      // Everything else in the corpus (still excluding both headlines
      // and the rotation-used set), shuffled, so swiping past the
      // similar handful leads into fresh, never-repeating material
      // instead of looping.
      final remainder = ranked
          .where((s) => !similarBandIds.contains(s.reflection.id))
          .map((s) => s.reflection)
          .toList()
        ..shuffle();

      pool = [...similar, ...remainder];
    } else {
      final all = await _embeddingService.allReflections();
      pool = List<EmbeddedReflection>.from(all)..shuffle();
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

  void _openBrowse() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BrowseScreen()),
    );
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
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
            icon: const Icon(Icons.location_on_outlined),
            tooltip: 'Weather location',
            onPressed: _openWeatherSettings,
          ),
          IconButton(
            icon: const Icon(Icons.favorite_border),
            tooltip: 'Favorites',
            onPressed: _openFavorites,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: _openHistory,
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
            if (!_exploring && _weatherSnapshot != null)
              WeatherStrip(snapshot: _weatherSnapshot!),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _exploring ? _buildExploreView() : _buildTabs(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs() {
    return TabBarView(
      key: const ValueKey('tabs'),
      controller: _tabController,
      children: [
        AmbientTab(
          reflection: _morning,
          loading: _loadingAmbient,
          unlocked: _isMorningUnlocked,
          lockedLabel: 'morning',
          lockedHint: 'Come back after 5:00 AM',
          lockedIcon: Icons.wb_twilight,
          fadeAnimation: _fadeAnimation,
          favoriteIds: _favoriteIds,
          onToggleFavorite: _toggleFavorite,
          onReroll: _rerollMorning,
          canReroll: _canRerollMorning,
          onExplore: () => _enterExplore(
            contextTimeId: 'time_morning',
            contextWeatherId: _morningWeatherId,
          ),
        ),
        OnDemandTab(
          reflection: _onDemand,
          loading: _onDemandLoading,
          favoriteIds: _favoriteIds,
          onToggleFavorite: _toggleFavorite,
          onCheckIn: _checkIn,
        ),
        AmbientTab(
          reflection: _evening,
          loading: _loadingEvening,
          unlocked: _isEveningUnlocked,
          lockedLabel: 'evening',
          lockedHint: 'Come back after 5:00 PM',
          lockedIcon: Icons.nights_stay_outlined,
          fadeAnimation: _fadeAnimation,
          favoriteIds: _favoriteIds,
          onToggleFavorite: _toggleFavorite,
          onReroll: _rerollEvening,
          canReroll: _canRerollEvening,
          onExplore: () => _enterExplore(
            contextTimeId: 'time_evening',
            contextWeatherId: _eveningWeatherId,
          ),
        ),
      ],
    );
  }

  Widget _buildExploreView() {
    return ExploreView(
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