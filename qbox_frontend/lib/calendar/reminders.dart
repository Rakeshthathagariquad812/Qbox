import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/qbox_user.dart';
import '../onboarding_draft.dart';
import '../services/notification_taps.dart';
import 'calendar_models.dart';

/// Phone notifications for calendar reminders. They are set on the phone
/// itself, so they ring even with no internet and with QBOX closed.
abstract class ReminderScheduler {
  /// Asks for permission to show notifications (Android 13+). True if allowed.
  Future<bool> askPermission();

  /// Replaces all reminders of one calendar with those of [events].
  Future<void> sync(QboxRole role, List<CalendarEvent> events);

  /// Removes every QBOX reminder (log out).
  Future<void> clearAll();

  /// Shows a notification straight away (e.g. "Rice is running low").
  /// [id] replaces an earlier notification with the same id.
  Future<void> showNow({required int id, required String title, required String body});

  /// What stops reminders from ringing on time, if anything.
  Future<ReminderProblem> problem();

  /// Opens the phone's page where exact-time reminders are allowed.
  Future<void> askExactTime();

  /// Replaces all supplier pay-by reminders with [dues] (each rings at 9 AM on its day).
  Future<void> syncDues(List<DueReminder> dues);
}

enum ReminderProblem { none, notificationsOff, notExact }

/// "Pay Ravi Traders ₹7,000 today", ringing at 9 AM on [day].
class DueReminder {
  const DueReminder({required this.id, required this.day, required this.title, required this.body});

  final int id;
  final DateTime day;
  final String title;
  final String body;
}

/// When a reminder should ring for [event], at or after [now]; null if never.
/// Pure date maths, kept outside the plugin so it can be tested.
DateTime? nextReminderTime(CalendarEvent event, DateTime now) {
  final before = event.remindMinutes;
  if (before == null) return null;
  // The reminder for an occurrence rings [before] minutes earlier, so look
  // for occurrences starting from now + before.
  final start = event.nextStart(now.add(Duration(minutes: before)));
  return start?.subtract(Duration(minutes: before));
}

/// The notification text for a reminder that rings at [remindAt]: which day
/// the event is (seen from the moment it rings), its time, and the note.
/// "Tomorrow · 10:00 AM · Payment", "Today · All day · Shop".
String reminderBody(CalendarEvent event, DateTime remindAt) {
  final start = remindAt.add(Duration(minutes: event.remindMinutes ?? 0));
  final days = DateTime.utc(start.year, start.month, start.day)
      .difference(DateTime.utc(remindAt.year, remindAt.month, remindAt.day))
      .inDays;
  final day = switch (days) {
    0 => 'Today',
    1 => 'Tomorrow',
    _ => longDate(start),
  };
  final time = event.minuteOfDay == null
      ? 'All day'
      : timeLabel(event.minuteOfDay!);
  final note = event.note.trim();
  return '$day · $time · ${note.isEmpty ? event.category.label : note}';
}

class LocalReminderScheduler implements ReminderScheduler {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channel = AndroidNotificationDetails(
    'qbox_calendar',
    'Calendar reminders',
    channelDescription: 'Reminders for events in your QBOX calendar',
    importance: Importance.high,
    priority: Priority.high,
  );

  Future<bool> _init() async {
    if (_ready) return true;
    try {
      tzdata.initializeTimeZones();
      // QBOX is for Indian shops; reminders use Indian time.
      tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: onLocalNotificationTap,
      );
      _ready = true;
    } catch (_) {
      _ready = false;
    }
    return _ready;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<bool> askPermission() async {
    if (!await _init()) return false;
    try {
      return await _android?.requestNotificationsPermission() ?? true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ReminderProblem> problem() async {
    if (!await _init()) return ReminderProblem.none;
    try {
      if (await _android?.areNotificationsEnabled() == false) return ReminderProblem.notificationsOff;
      if (await _android?.canScheduleExactNotifications() == false) return ReminderProblem.notExact;
    } catch (_) {}
    return ReminderProblem.none;
  }

  @override
  Future<void> askExactTime() async {
    if (!await _init()) return;
    try {
      await _android?.requestExactAlarmsPermission();
    } catch (_) {}
  }

  /// At the exact minute when the user allows it; else Android may ring late.
  /// The alarm-clock kind: the others were still held back on some phones (OPPO).
  Future<AndroidScheduleMode> _mode() async {
    try {
      if (await _android?.canScheduleExactNotifications() ?? false) return AndroidScheduleMode.alarmClock;
    } catch (_) {}
    return AndroidScheduleMode.inexactAllowWhileIdle;
  }

  /// One at a time, so two do not undo each other.
  Future<void> _last = Future.value();

  @override
  Future<void> sync(QboxRole role, List<CalendarEvent> events) => _last = _last.then((_) => _sync(role, events));

  Future<void> _sync(QboxRole role, List<CalendarEvent> events) async {
    if (!await _init()) return;
    try {
      final mode = await _mode();
      final tag = 'role:${roleCode(role)}';
      for (final pending in await _plugin.pendingNotificationRequests()) {
        if (pending.payload == tag) await _plugin.cancel(id: pending.id);
      }
      final now = DateTime.now();
      for (final event in events) {
        final at = nextReminderTime(event, now);
        if (at == null) continue;
        await _plugin.zonedSchedule(
          id: _notificationId(role, event.id),
          scheduledDate: tz.TZDateTime.from(at, tz.local),
          notificationDetails: const NotificationDetails(android: _channel),
          androidScheduleMode: mode,
          title: event.title,
          body: reminderBody(event, at),
          payload: tag,
          matchDateTimeComponents: _repeatMatch(event.repeat),
        );
      }
    } catch (_) {
      // Reminders are a bonus: never let them break the calendar.
    }
  }

  @override
  Future<void> clearAll() async {
    if (!await _init()) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  static const _stockChannel = AndroidNotificationDetails(
    'qbox_stock',
    'Low stock',
    channelDescription: 'When an item in your QBOX stock is running low',
    importance: Importance.high,
    priority: Priority.high,
  );

  @override
  Future<void> showNow({required int id, required String title, required String body}) async {
    if (!await _init()) return;
    try {
      // Stock notifications use ids from 2^30 up, apart from calendar reminders.
      await _plugin.show(
        id: (id & 0x3fffffff) | 0x40000000,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(android: _stockChannel),
      );
    } catch (_) {
      // A bonus: never let it break the screen.
    }
  }

  static const _duesTag = 'supplier-dues';

  @override
  Future<void> syncDues(List<DueReminder> dues) async {
    if (!await _init()) return;
    try {
      for (final pending in await _plugin.pendingNotificationRequests()) {
        if (pending.payload == _duesTag) await _plugin.cancel(id: pending.id);
      }
      final now = DateTime.now();
      final mode = await _mode();
      for (final due in dues) {
        final at = DateTime(due.day.year, due.day.month, due.day.day, 9);
        if (!at.isAfter(now)) continue;
        await _plugin.zonedSchedule(
          // Supplier reminders use ids from 3 x 2^29 up, apart from the others.
          id: (due.id & 0x1fffffff) | 0x60000000,
          scheduledDate: tz.TZDateTime.from(at, tz.local),
          notificationDetails: const NotificationDetails(android: _channel),
          androidScheduleMode: mode,
          title: due.title,
          body: due.body,
          payload: _duesTag,
        );
      }
    } catch (_) {
      // Reminders are a bonus: never let them break the screen.
    }
  }

  /// Events added without internet (ids below 0) have a range of their own.
  static int _notificationId(QboxRole role, int eventId) => eventId < 0
      ? 0x3f000000 | ((-eventId * 4 + role.index) & 0xffffff)
      : (eventId * 4 + role.index) & 0x7fffffff;

  static DateTimeComponents? _repeatMatch(Repeat repeat) => switch (repeat) {
    Repeat.none => null,
    Repeat.daily => DateTimeComponents.time,
    Repeat.weekly => DateTimeComponents.dayOfWeekAndTime,
    Repeat.monthly => DateTimeComponents.dayOfMonthAndTime,
    Repeat.yearly => DateTimeComponents.dateAndTime,
  };
}
