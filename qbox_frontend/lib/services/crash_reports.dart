import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Crash reports (Firebase Crashlytics): when the app crashes on someone's
/// phone, a short technical report (where in the code, which phone and app
/// version) goes to the QBOX team. No PINs, names, numbers or money details.
///
/// Only in the finished (release) app on Android, and only when the app was
/// built with the Firebase file (android/app/google-services.json). Otherwise
/// it does nothing, so the app works exactly as before.
Future<void> startCrashReports() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android || !kReleaseMode) return;
  try {
    await Firebase.initializeApp();
  } catch (_) {
    return; // built without the Firebase file: no crash reports
  }
  final crashlytics = FirebaseCrashlytics.instance;
  await crashlytics.setCrashlyticsCollectionEnabled(true);
  // Errors in QBOX's own screens and code.
  FlutterError.onError = crashlytics.recordFlutterFatalError;
  // Errors that happen outside a screen (background work, timers).
  PlatformDispatcher.instance.onError = (error, stack) {
    crashlytics.recordError(error, stack, fatal: true);
    return true;
  };
}
