import 'package:flutter/foundation.dart';
import 'package:qbox_app/onboarding_draft.dart';
import 'package:qbox_app/services/push_notifications.dart';

/// Pretend push notifications: counts start/stop; [tap] acts like tapping one.
class FakePush implements PushNotifications {
  final ValueNotifier<QboxRole?> _opened = ValueNotifier(null);
  int starts = 0;
  int stops = 0;
  AlertPrefs saved = const AlertPrefs();

  void tap(QboxRole role) => _opened.value = role;

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> stop() async => stops++;

  @override
  ValueListenable<QboxRole?> get opened => _opened;

  @override
  void handled() => _opened.value = null;

  @override
  Future<AlertPrefs> prefs() async => saved;

  @override
  Future<void> savePrefs(AlertPrefs prefs) async => saved = prefs;
}
