import 'dart:math';
import 'package:flutter/material.dart';
import '../models/quote.dart';
import '../services/quote_storage_service.dart';
import '../services/notification_service.dart';
import '../data/quote_repository.dart';
import 'browse_screen.dart';
import 'add_quote_screen.dart';

/// The main screen — shows today's quote, fading in slowly.
/// The quote itself is picked and persisted by [QuoteStorageService]:
/// it stays fixed for the whole day and won't repeat until every
/// quote in the pool has been shown once (then the cycle resets).
///
/// From here you can also enter "explore mode": today's quote
/// minimizes to a small strip up top, and a swipeable/tappable feed of
/// other quotes appears below it. Explore mode is purely in-memory —
/// it never changes which quote is "today's", and nothing about it
/// is persisted.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  final QuoteStorageService _storage = QuoteStorageService();
  final NotificationService _notifications = NotificationService();
  final QuoteRepository _repository = QuoteRepository();

  Quote? _quote;
  bool _loading = true;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  // --- Explore mode state ---
  bool _exploring = false;
  final PageController _pageController = PageController();
  List<Quote> _explorePool = [];

  // How long you have to wait the *first* time you land on a quote
  // before you can move on — long enough to actually read it, short
  // enough not to feel like a wait. Going back to re-read a quote
  // you've already sat with is always instant.
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
      duration: const Duration(seconds: 4), // slow, deliberate fade-in
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

    _loadQuote();
  }

  Future<void> _loadQuote() async {
    final todaysQuote = await _storage.getTodaysQuote();

    setState(() {
      _quote = todaysQuote;
      _loading = false;
    });

    // Small delay before starting the fade so the screen doesn't
    // feel like it's rushing to show something the moment it opens.
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) _fadeController.forward();

    // Pre-assign and schedule tomorrow's notification now, while we
    // have a live app process. See NotificationService for why this
    // has to happen at open-time rather than at fire-time.
    _scheduleTomorrowNotification();
  }

  Future<void> _scheduleTomorrowNotification() async {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final tomorrowKey = QuoteStorageService.dateToString(tomorrow);
    final tomorrowsQuote =
        await _storage.getOrAssignQuoteForDate(tomorrowKey);

    await _notifications.init();
    await _notifications.scheduleTomorrow(
      quote: tomorrowsQuote,
      hour: 8, // adjust to your preferred notification time
      minute: 0,
    );
  }

  /// Enters explore mode: shuffles the full quote pool and shows it as
  /// a swipeable/tappable feed, with today's quote minimized above it.
  Future<void> _enterExplore() async {
    final all = await _repository.loadAll();
    final shuffled = List<Quote>.from(all)..shuffle();

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

  /// Called whenever the visible quote changes (swipe forward, swipe
  /// back, or tap-to-advance). If this quote has already had its
  /// cooldown satisfied before — most commonly because you swiped back
  /// to re-read it — it's unlocked instantly. Only a genuinely new
  /// quote starts a fresh cooldown.
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

  /// Advances the explore feed by one, looping back to the start at
  /// the end. Used when the current quote itself is tapped. Blocked
  /// until the read cooldown for the current quote has finished.
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

  Future<void> _openAddQuote() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AddQuoteScreen()),
    );
  }

  void _openBrowse() {
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
      backgroundColor: const Color(0xFFFBF3E9), // warm cream
      appBar: AppBar(
        backgroundColor: const Color(0xFFFBF3E9),
        foregroundColor: const Color(0xFF3B2E28),
        elevation: 0,
        title: const Text('Daily Quote'),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: 'Browse all quotes',
            onPressed: _openBrowse,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add a quote',
            onPressed: _openAddQuote,
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

  /// Today's fixed quote, centered and dominant, with a quiet entry
  /// point into explore mode pinned near the bottom of the screen —
  /// kept separate so it doesn't compete with the quote itself.
  Widget _buildTodayView() {
    if (_loading) {
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '"${_quote!.text}"',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontStyle: FontStyle.italic,
                        height: 1.5,
                        color: Color(0xFF3B2E28), // warm dark brown
                        fontFamily: 'Georgia', // serif, unhurried feel
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '— ${_quote!.author}',
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF8A6F5C),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
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
            label: const Text('See other quotes'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF8A6F5C),
            ),
          ),
        ),
      ],
    );
  }

  /// Today's quote minimized up top, plus a swipeable/tappable feed of
  /// other quotes below it.
  Widget _buildExploreView() {
    return Column(
      key: const ValueKey('explore'),
      children: [
        if (_quote != null)
          _MinimizedTodayQuote(quote: _quote!, onTap: _exitExplore),
        Expanded(
          child: _explorePool.isEmpty
              ? const Center(child: Text('No other quotes yet.'))
              : PageView.builder(
                  controller: _pageController,
                  onPageChanged: _startReadCooldown,
                  itemCount: _explorePool.length,
                  itemBuilder: (context, index) {
                    final q = _explorePool[index];
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _showNextExploreQuote,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '"${q.text}"',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontStyle: FontStyle.italic,
                                  height: 1.5,
                                  color: Color(0xFF3B2E28),
                                  fontFamily: 'Georgia',
                                ),
                              ),
                              const SizedBox(height: 18),
                              Text(
                                '— ${q.author}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF8A6F5C),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
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

/// The small pinned strip shown at the top during explore mode. Tapping
/// it returns you to the full "today" view.
class _MinimizedTodayQuote extends StatelessWidget {
  final Quote quote;
  final VoidCallback onTap;

  const _MinimizedTodayQuote({required this.quote, required this.onTap});

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
                '"${quote.text}" — ${quote.author}',
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

/// A tiny, unobtrusive loading indicator — not a spinner,
/// keeps the same quiet tone as the rest of the app.
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