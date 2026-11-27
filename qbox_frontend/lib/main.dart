import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'onboarding_draft.dart';
import 'phone_stage.dart';
import 'services/api_config.dart';
import 'services/app_services.dart';
import 'services/crash_reports.dart';
import 'services/push_notifications.dart';
import 'splash_screen.dart';
import 'startup_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await startCrashReports();
  listenInBackground(); // push notifications that are said aloud while QBOX is closed
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0xFFF4F0FD),
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ),
  );
  final problem = apiUrlProblem(qboxApiBaseUrl(), release: kReleaseMode);
  if (problem != null) {
    // Made wrongly: it must not send anyone's PIN anywhere.
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text('QBOX cannot start: $problem.', textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
    return;
  }
  runApp(QboxApp(services: AppServices.live(), showSplash: true));
}

class QboxApp extends StatefulWidget {
  const QboxApp({required this.services, this.showSplash = false, super.key});

  /// The backend connection. Tests pass a fake one.
  final AppServices services;

  /// The opening animation (QBOX lines, "powered by Quadrant IT Services").
  final bool showSplash;

  @override
  State<QboxApp> createState() => _QboxAppState();
}

class _QboxAppState extends State<QboxApp> {
  final OnboardingDraft _draft = OnboardingDraft();

  @override
  Widget build(BuildContext context) {
    return ServicesScope(
      services: widget.services,
      child: OnboardingScope(
      draft: _draft,
      child: MaterialApp(
        title: 'QBOX',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'Poppins',
          scaffoldBackgroundColor: Colors.white,
        ),
        builder: (context, child) {
          return PhoneStage(child: child ?? const SizedBox.shrink());
        },
        home: widget.showSplash ? const SplashScreen(next: StartupGate()) : const StartupGate(),
      ),
      ),
    );
  }
}
