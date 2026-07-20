import 'package:flutter/material.dart';
import '../models/quote.dart';
import '../services/quote_storage_service.dart';
import '../services/notification_service.dart';

/// The main screen — shows today's quote, fading in slowly.
/// The quote itself is picked and persisted by [QuoteStorageService]:
/// it stays fixed for the whole day and won't repeat until every
/// quote in the pool has been shown once (then the cycle resets).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final QuoteStorageService _storage = QuoteStorageService();
  final NotificationService _notifications = NotificationService();

  Quote? _quote;
  bool _loading = true;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

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

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBF3E9), // warm cream
      body: SafeArea(
        child: Center(
          child: _loading
              ? const _QuietLoadingDot()
              : Padding(
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