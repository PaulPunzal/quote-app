import 'dart:math';
import 'package:flutter/material.dart';
import '../models/embedded_reflection.dart';
import '../services/reflection_daily_service.dart';
import '../services/reflection_embedding_service.dart';
import '../services/notification_service.dart';
import '../widgets/mood_check_in_sheet.dart';
import 'browse_screen.dart';

/// The main screen — shows today's reflection, fading in slowly.
///
/// Picking is now handled by ReflectionDailyService: mood comes from a
/// quick check-in sheet, weather is stubbed out for now (see
/// _currentWeatherId below), and time-of-day is computed automatically
/// from the clock. Once picked, today's reflection stays fixed for the
/// rest of the day, same as the old quote system.
///
/// Explore mode below still works the same way conceptually — a
/// shuffled feed of other reflections you can swipe through — but now
/// pulls from the embedded reflection pool instead of the old tagged
/// quote pool.
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

  EmbeddedReflection? _reflection;
  bool _loading = true;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  // --- Explore mode state ---
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

    _loadReflection();
  }

  /// TODO(weather): stubbed for now — always returns null, so matching
  /// runs on mood + time only. Once a weather source is wired in, map
  /// its condition to one of the 'weather_*' ids from
  /// context_options.json and return that instead.
  Future<String?> _currentWeatherId() async {
    return null;
  }

  Future<void> _loadReflection() async {
    // If today's reflection was already picked (e.g. reopening the app
    // later the same day), just show it — no need to ask mood again.
    final alreadyPicked = await _dailyService.getTodaysReflectionIfAssigned();

    EmbeddedReflection reflection;
    if (alreadyPicked != null) {
      reflection = alreadyPicked;
    } else {
      if (!mounted) return;
      final moodId = await MoodCheckInSheet.show(context);

      if (moodId == null) {
        // Sheet was dismissed without a choice. isDismissible is false
        // on the sheet itself, so this path is mostly a safety net --
        // still, don't leave the screen stuck loading forever.
        if (mounted) setState(() => _loading = false);
        return;
      }

      final weatherId = await _currentWeatherId();
      reflection = await _dailyService.getTodaysReflection(
        moodId: moodId,
        weatherId: weatherId,
      );
    }

    if (!mounted) return;
    setState(() {
      _reflection = reflection;
      _loading = false;
    });

    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) _fadeController.forward();

    _scheduleTomorrowNotification();
  }

  /// See the class-level note: tomorrow's *specific* reflection can't
  /// be pre-picked, because picking depends on tomorrow's mood, which
  /// isn't known yet. Rather than guess (and risk showing a mismatched
  /// reflection in the notification body, or reusing today's), this
  /// schedules a generic, non-spoiling reminder instead. Revisit this
  /// once there's a plan for mood-independent notification content.
  Future<void> _scheduleTomorrowNotification() async {
    await _notifications.init();
    await _notifications.scheduleTomorrowGeneric(
      hour: 8,
      minute: 0,
    );
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

  void _showNextExploreQuote() {
    if (!_canAdvance || _explorePool.length < 2) return;

    final current =
        _pageController.hasClients ? (_pageController.page ?? 0).round() : 0;
    final next = (current + 1) % _explorePool.length;

    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  void _openBrowse() {
    // NOTE: still browses the legacy tagged Quote pool, not the
    // embedded reflections. Revisit once Browse is updated to read
    // from reflections.json.
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BrowseScreen()),
    );
  }

  @override
  void dispose() {
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
          child: _exploring ? _buildExploreView() : _buildTodayView(),
        ),
      ),
    );
  }

  Widget _buildTodayView() {
    if (_loading || _reflection == null) {
      return const Center(key: ValueKey('today'), child: _QuietLoadingDot());
    }

    return Column(
      key: const ValueKey('today'),
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Text(
                  _reflection!.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontStyle: FontStyle.italic,
                    height: 1.5,
                    color: Color(0xFF3B2E28),
                    fontFamily: 'Georgia',
                  ),
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

  Widget _buildExploreView() {
    return Column(
      key: const ValueKey('explore'),
      children: [
        if (_reflection != null)
          _MinimizedTodayReflection(
            reflection: _reflection!,
            onTap: _exitExplore,
          ),
        Expanded(
          child: _explorePool.isEmpty
              ? const Center(child: Text('No other reflections yet.'))
              : PageView.builder(
                  controller: _pageController,
                  onPageChanged: _startReadCooldown,
                  itemCount: _explorePool.length,
                  itemBuilder: (context, index) {
                    final r = _explorePool[index];
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _showNextExploreQuote,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Center(
                          child: Text(
                            r.text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 20,
                              fontStyle: FontStyle.italic,
                              height: 1.5,
                              color: Color(0xFF3B2E28),
                              fontFamily: 'Georgia',
                            ),
                          ),
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
            _canAdvance ? 'Swipe or tap for another' : 'Take a moment…',
            style: const TextStyle(fontSize: 11, color: Color(0xFF8A6F5C)),
          ),
        ),
      ],
    );
  }
}

class _MinimizedTodayReflection extends StatelessWidget {
  final EmbeddedReflection reflection;
  final VoidCallback onTap;

  const _MinimizedTodayReflection({
    required this.reflection,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF0E4D4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.today, size: 16, color: Color(0xFF8A6F5C)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                reflection.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFF3B2E28),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.close, size: 16, color: Color(0xFF8A6F5C)),
          ],
        ),
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