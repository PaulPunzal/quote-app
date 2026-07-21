import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

/// Handles scheduling the daily local notification.
///
/// Important design note: flutter_local_notifications can't run Dart
/// code at the moment a scheduled notification fires (no background
/// isolate for content generation without extra platform setup), so
/// we can't pick "tomorrow's reflection" *at* fire time. Instead, this
/// schedules a generic, non-spoiling reminder — the actual reflection
/// is picked when the app is opened and (for the on-demand slot) the
/// mood check-in happens, which can't be known a day ahead anyway.
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

  /// Schedules a generic, non-spoiling reminder for tomorrow at
  /// [hour]:[minute] — picking depends on mood, which isn't knowable a
  /// day ahead. This doesn't bake in any reflection text; it just
  /// prompts the person to open the app, where the real pick happens
  /// after their mood check-in.
  Future<void> scheduleTomorrowGeneric({
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

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'daily_quote_channel',
        'Daily Quote',
        channelDescription: 'Delivers one quote per day',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.zonedSchedule(
      _dailyNotificationId,
      "Today's reflection is ready",
      'Take a moment — a new reflection is waiting for you.',
      scheduledDate,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
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
}