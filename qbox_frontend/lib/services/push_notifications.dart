// The classic FCM registration token (getToken, onTokenRefresh, deleteToken) is used on
// purpose: firebase_messaging 17 marks it deprecated in favour of a newer installation-ID
// send, but the server's HTTP v1 send to a token is the long-proven way and still works.
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../calculator/voice_services.dart';
import '../models/qbox_user.dart';
import '../onboarding_draft.dart';
import '../payments/payment_models.dart';
import '../translator/languages.dart';
import '../translator/voice_language.dart';
import '../udhaar/udhaar_models.dart' show rupees;
import 'api_client.dart';
import 'notification_taps.dart';
import 'settings_store.dart';

/// Push notifications (Firebase Cloud Messaging): the bell, on the phone the moment
/// it happens, even with QBOX closed. The server decides what is sent (the same
/// rules as the bell); the phone only says where to send it, and opens the bell
/// when one is tapped.
///
/// Per phone, chosen in "Choose notifications" (see [AlertPrefs]): which kinds are
/// also said aloud, in which voice, and quiet hours (silent, nothing said).
abstract class PushNotifications {
  /// Logged in: this phone gets this user's notifications. Asks once to allow
  /// notifications (Android 13 and later).
  Future<void> start();

  /// Log out: this phone gets no more notifications.
  Future<void> stop();

  /// A notification was tapped: the role whose bell should open.
  ValueListenable<QboxRole?> get opened;

  /// The bell was opened: [opened] goes back to null.
  void handled();

  /// This phone's alert settings.
  Future<AlertPrefs> prefs();

  /// Saves them (the server is told, so it sends spoken kinds in a way the phone can
  /// speak, and quiet hours silently).
  Future<void> savePrefs(AlertPrefs prefs);
}

/// One phone's choices for alerts. Kept with the other small settings, so they stay
/// after log out.
class AlertPrefs {
  const AlertPrefs({this.spoken = const {}, this.quietFrom, this.quietTo, this.voice});

  /// Kinds said aloud, as "ROLE:TYPE" ("BUSINESS:PAYMENT"), the server's words.
  final Set<String> spoken;

  /// Quiet hours in minutes after midnight; both null = none.
  final int? quietFrom;
  final int? quietTo;

  /// The phone voice chosen for alerts; null = the phone's usual one.
  final String? voice;

  bool get hasQuietHours => quietFrom != null && quietTo != null;

  static String key(QboxRole role, String type) => '${roleCode(role)}:$type';

  bool speaks(QboxRole role, String type) => spoken.contains(key(role, type));

  /// Is [minute] (after midnight) inside the quiet hours? They may cross midnight.
  bool isQuiet(int minute) {
    final from = quietFrom, to = quietTo;
    if (from == null || to == null || from == to) return false;
    return from < to ? minute >= from && minute < to : minute >= from || minute < to;
  }

  AlertPrefs copyWith({Set<String>? spoken, int? quietFrom, int? quietTo, bool noQuiet = false, String? voice,
      bool usualVoice = false}) =>
      AlertPrefs(
        spoken: spoken ?? this.spoken,
        quietFrom: noQuiet ? null : quietFrom ?? this.quietFrom,
        quietTo: noQuiet ? null : quietTo ?? this.quietTo,
        voice: usualVoice ? null : voice ?? this.voice,
      );

  Map<String, Object?> toJson() =>
      {'spoken': spoken.toList()..sort(), 'quietFrom': quietFrom, 'quietTo': quietTo, 'voice': voice};

  static AlertPrefs fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const AlertPrefs();
    int? minute(Object? v) => v is int && v >= 0 && v < 24 * 60 ? v : null;
    final from = minute(json['quietFrom']), to = minute(json['quietTo']);
    return AlertPrefs(
      spoken: {for (final k in json['spoken'] as List? ?? const []) if (k is String) k},
      quietFrom: from != null && to != null ? from : null,
      quietTo: from != null && to != null ? to : null,
      voice: json['voice'] is String ? json['voice'] as String : null,
    );
  }
}

const alertPrefsKey = 'alert_prefs';

/// Money coming in: what the first test builds' "speak money alerts" meant.
const _moneySpoken = {'BUSINESS:PAYMENT', 'SUPPLIER:LEDGER'};

Future<AlertPrefs> readAlertPrefs(SettingsStore settings) async {
  final saved = await settings.read(alertPrefsKey);
  if (saved != null) {
    try {
      return AlertPrefs.fromJson(jsonDecode(saved));
    } on FormatException {
      return const AlertPrefs();
    }
  }
  // Earlier test builds.
  final mode = await settings.read('speak_alerts');
  if (mode == 'MONEY' || await settings.read('speak_money_alerts') == '1') {
    return const AlertPrefs(spoken: _moneySpoken);
  }
  return const AlertPrefs();
}

Future<void> writeAlertPrefs(SettingsStore settings, AlertPrefs prefs) =>
    settings.write(alertPrefsKey, jsonEncode(prefs.toJson()));

/// Tests, and app builds without Firebase: nothing is sent to this phone.
class NoPushNotifications implements PushNotifications {
  NoPushNotifications([SettingsStore? settings]) : _settings = settings ?? MemorySettingsStore();

  final SettingsStore _settings;
  final ValueNotifier<QboxRole?> _opened = ValueNotifier(null);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  ValueListenable<QboxRole?> get opened => _opened;

  @override
  void handled() => _opened.value = null;

  @override
  Future<AlertPrefs> prefs() => readAlertPrefs(_settings);

  @override
  Future<void> savePrefs(AlertPrefs prefs) => writeAlertPrefs(_settings, prefs);
}

const _alerts = AndroidNotificationChannel(
  'qbox_alerts',
  'Alerts',
  description: 'Payments, udhaar, orders and other news in your bell',
  importance: Importance.high,
);

const _quiet = AndroidNotificationChannel(
  'qbox_quiet',
  'Quiet hours',
  description: 'News during the quiet hours you chose, without sound',
  importance: Importance.low,
);

const _payloadPrefix = 'push:';

/// What is said aloud for an alert, in [language]. Money and the most common alerts
/// have words in every language; the rest are said as their English title.
String spokenAlert(Map<String, dynamic> data, AppLanguage language) {
  final paise = int.tryParse('${data['amount'] ?? ''}') ?? 0;
  final name = '${data['name'] ?? ''}'.trim();
  final amount = rupees(paise).replaceAll('₹', '').replaceAll(',', '');
  final title = '${data['title'] ?? ''}';
  return switch (data['kind']) {
    'PAID_ONLINE' => receivedWords(paise, language, from: name),
    'SAYS_PAID' || 'CONFIRM_PAYMENT' => saysPaidWords(paise, language, from: name),
    'CREDIT' => switch (language) {
      AppLanguage.telugu => '$name $amount రూపాయల అప్పు రాశారు',
      AppLanguage.hindi => '$name ने $amount रुपये उधार लिखे',
      AppLanguage.kannada => '$name $amount ರೂಪಾಯಿ ಸಾಲ ಬರೆದಿದ್ದಾರೆ',
      AppLanguage.tamil => '$name $amount ரூபாய் கடன் எழுதியுள்ளார்',
      AppLanguage.english => '$name wrote $amount rupees udhaar',
    },
    'RECORDED' => switch (language) {
      AppLanguage.telugu => '$name మీ $amount రూపాయల చెల్లింపు నమోదు చేశారు',
      AppLanguage.hindi => '$name ने आपका $amount रुपये का भुगतान दर्ज किया',
      AppLanguage.kannada => '$name ನಿಮ್ಮ $amount ರೂಪಾಯಿ ಪಾವತಿಯನ್ನು ದಾಖಲಿಸಿದ್ದಾರೆ',
      AppLanguage.tamil => '$name உங்கள் $amount ரூபாய் கட்டணத்தைப் பதிவு செய்தார்',
      AppLanguage.english => '$name recorded your payment of $amount rupees',
    },
    'NEW_ORDER' => switch (language) {
      AppLanguage.telugu => '$name నుండి కొత్త ఆర్డర్',
      AppLanguage.hindi => '$name से नया ऑर्डर',
      AppLanguage.kannada => '$name ಅವರಿಂದ ಹೊಸ ಆರ್ಡರ್',
      AppLanguage.tamil => '$name இடமிருந்து புதிய ஆர்டர்',
      AppLanguage.english => 'New order from $name',
    },
    'LOW_STOCK' || 'PRODUCT_LOW' => switch (language) {
      AppLanguage.telugu => '$name తక్కువగా ఉంది',
      AppLanguage.hindi => '$name कम हो रहा है',
      AppLanguage.kannada => '$name ಕಡಿಮೆ ಇದೆ',
      AppLanguage.tamil => '$name குறைவாக உள்ளது',
      AppLanguage.english => '$name is running low',
    },
    _ => title,
  };
}

/// Says an alert with the phone's prefs: in the voice language, in the chosen voice.
Future<void> sayAlert(Speaker speaker, String words, AppLanguage language, {String? voice}) async {
  if (speaker is VoiceChoices && voice != null) {
    await (speaker as VoiceChoices).sayWith(words, locale: language.voiceLocale, voice: voice);
  } else {
    await speaker.say(words, locale: language.voiceLocale);
  }
}

/// Should this alert be said aloud now? (The server already sends nothing to speak
/// during quiet hours; checked again in case the setting just changed.)
bool shouldSpeak(AlertPrefs prefs, Map<String, dynamic> data, DateTime now) {
  final role = roleFromCode('${data['role'] ?? ''}');
  return role != null && prefs.speaks(role, '${data['type'] ?? ''}') && !prefs.isQuiet(now.hour * 60 + now.minute);
}

/// An alert sent for speaking: shown by the app itself (Android does not show these
/// by itself), then said aloud. Used both while QBOX is open and, through
/// [qboxBackgroundMessage], while it is closed.
Future<void> _showAndSpeak(RemoteMessage message, FlutterLocalNotificationsPlugin local) async {
  final data = message.data;
  final quiet = data['channel'] == _quiet.id;
  await _show(
    local,
    id: '${data['tag'] ?? message.messageId}'.hashCode & 0x0fffffff,
    title: '${data['title'] ?? ''}',
    body: '${data['body'] ?? ''}',
    quiet: quiet,
    role: data['role'],
  );
  final settings = PrefsSettingsStore();
  final prefs = await readAlertPrefs(settings);
  if (!shouldSpeak(prefs, data, DateTime.now())) return;
  final speaker = DeviceSpeaker();
  var language = await readVoiceLanguage(settings);
  if (!await speaker.hasVoice(language.voiceLocale)) language = AppLanguage.english;
  final words = spokenAlert(data, language);
  if (words.trim().isEmpty) return;
  await sayAlert(speaker, words, language, voice: prefs.voice);
  await speaker.finished; // the phone may close QBOX again as soon as this ends
}

Future<void> _show(
  FlutterLocalNotificationsPlugin local, {
  required int id,
  required String? title,
  required String? body,
  required bool quiet,
  required Object? role,
}) async {
  final channel = quiet ? _quiet : _alerts;
  try {
    await local.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: quiet ? Priority.low : Priority.high,
        ),
      ),
      payload: '$_payloadPrefix${role ?? ''}',
    );
  } catch (_) {}
}

/// Runs in the background (QBOX closed) for messages sent as data: the money alerts
/// of phones that speak them. Must be a top-level function.
@pragma('vm:entry-point')
Future<void> qboxBackgroundMessage(RemoteMessage message) async {
  if (message.data['speak'] != '1') return;
  try {
    WidgetsFlutterBinding.ensureInitialized();
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    final local = FlutterLocalNotificationsPlugin();
    await local.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    await _showAndSpeak(message, local);
  } catch (_) {
    // Nothing can be shown to anyone from here.
  }
}

/// Called in main() once Firebase is started: background messages go to
/// [qboxBackgroundMessage].
void listenInBackground() {
  if (Firebase.apps.isEmpty) return;
  FirebaseMessaging.onBackgroundMessage(qboxBackgroundMessage);
}

class FirebasePushNotifications implements PushNotifications {
  FirebasePushNotifications(this._api, this._settings);

  final ApiClient _api;
  final SettingsStore _settings;
  final ValueNotifier<QboxRole?> _opened = ValueNotifier(null);
  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  final List<StreamSubscription<Object?>> _listening = [];
  String? _token;
  bool _set = false;

  /// Firebase is started in main() (crash_reports.dart), only in the finished app.
  bool get _on => Firebase.apps.isNotEmpty;

  @override
  ValueListenable<QboxRole?> get opened => _opened;

  @override
  void handled() => _opened.value = null;

  @override
  Future<AlertPrefs> prefs() => readAlertPrefs(_settings);

  @override
  Future<void> savePrefs(AlertPrefs prefs) async {
    await writeAlertPrefs(_settings, prefs);
    final token = _token;
    if (_on && token != null) await _register(token);
  }

  @override
  Future<void> start() async {
    if (!_on) return;
    try {
      await _setUp();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) await _register(token);
      // Opened from a notification while QBOX was closed.
      final first = await messaging.getInitialMessage();
      if (first != null) _open(first.data['role']);
      final launch = await _local.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) _tapped(launch?.notificationResponse?.payload);
    } catch (_) {
      // A bonus: never let it break logging in.
    }
  }

  Future<void> _setUp() async {
    if (_set) return;
    _set = true;
    await _local.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: onLocalNotificationTap,
    );
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_alerts);
    await android?.createNotificationChannel(_quiet);
    _listening
      ..add(FirebaseMessaging.instance.onTokenRefresh.listen((token) => unawaited(_register(token))))
      ..add(FirebaseMessaging.onMessageOpenedApp.listen((message) => _open(message.data['role'])))
      ..add(FirebaseMessaging.onMessage.listen(_whileOpen))
      ..add(notificationTaps.stream.listen(_tapped));
  }

  Future<void> _register(String token) async {
    _token = token;
    try {
      final prefs = await this.prefs();
      await _api.post('/api/devices', {
        'token': token,
        'speak': prefs.spoken.toList()..sort(),
        'quietFrom': prefs.quietFrom,
        'quietTo': prefs.quietTo,
      }, timeout: const Duration(seconds: 15));
    } catch (_) {
      // Tried again the next time QBOX opens.
    }
  }

  /// While QBOX is open Android does not show it by itself.
  Future<void> _whileOpen(RemoteMessage message) async {
    if (message.data['speak'] == '1') return _showAndSpeak(message, _local);
    final note = message.notification;
    if (note == null) return;
    await _show(
      _local,
      id: '${message.data['notice'] ?? message.messageId}'.hashCode & 0x0fffffff,
      title: note.title,
      body: note.body,
      quiet: note.android?.channelId == _quiet.id,
      role: message.data['role'],
    );
  }

  void _tapped(String? payload) {
    if (payload != null && payload.startsWith(_payloadPrefix)) _open(payload.substring(_payloadPrefix.length));
  }

  void _open(Object? role) {
    final found = role is String ? roleFromCode(role) : null;
    if (found == null) return;
    // Told again even if the same role was opened before.
    _opened.value = null;
    _opened.value = found;
  }

  @override
  Future<void> stop() async {
    _opened.value = null;
    if (!_on) return;
    try {
      final token = _token ?? await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _api.post('/api/devices/forget', {'token': token}, timeout: const Duration(seconds: 5));
      }
    } catch (_) {
      // Offline: the token is deleted below, so the server can no longer reach this phone.
    }
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
    _token = null;
  }
}
