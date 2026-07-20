import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import '../models/quote.dart';

/// Handles scheduling the daily local notification.
///
/// Important design note: flutter_local_notifications can't run Dart
/// code at the moment a scheduled notification fires (no background
/// isolate for content generation without extra platform setup), so
/// we can't pick "tomorrow's quote" *at* fire time. Instead, every
/// time the app is opened, we pre-compute and schedule tomorrow's
/// notification with the *actual* quote text already baked in. This
/// means the chain stays accurate as long as the app is opened at
/// least once a day (which naturally happens, since opening it is
/// how you read today's quote in the first place).
class NotificationService {
  static const int _dailyNotificationId = 1001;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    // Uses the device's current offset to pick a matching timezone.
    // Good enough for a personal, single-user, single-device app.
    tz.setLocalLocation(tz.local);

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false, // we ask explicitly below
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
    );

    await _requestPermissions();
    _initialized = true;
  }

  Future<void> _requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// Cancels any previously scheduled daily notification and schedules
  /// a new one for tomorrow at [hour]:[minute], using [quote]'s real
  /// text and author as the notification body — so even if it's
  /// dismissed without tapping, the content was already delivered in
  /// the expanded notification itself.
  Future<void> scheduleTomorrow({
    required Quote quote,
    int hour = 8,
    int minute = 0,
  }) async {
    await _plugin.cancel(_dailyNotificationId);

    final now = tz.TZDateTime.now(tz.local);
    final scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    ).add(const Duration(days: 1));

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'daily_quote_channel',
        'Daily Quote',
        channelDescription: 'Delivers one quote per day',
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(
          '"${quote.text}" — ${quote.author}',
        ),
      ),
      iOS: const DarwinNotificationDetails(),
    );

    await _plugin.zonedSchedule(
      _dailyNotificationId,
      "Today's quote",
      '"${quote.text}" — ${quote.author}',
      scheduledDate,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}