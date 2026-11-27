import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qbox_app/main.dart';
import 'package:qbox_app/onboarding_draft.dart';
import 'package:qbox_app/profile/notices.dart';
import 'package:qbox_app/profile/notices_screen.dart';
import 'package:qbox_app/services/push_notifications.dart';
import 'package:qbox_app/services/session_store.dart';
import 'package:qbox_app/services/settings_store.dart';
import 'package:qbox_app/translator/languages.dart';

import 'fake_auth_api.dart';
import 'fake_push.dart';
import 'widget_test.dart' show usePhone;

void main() {
  Future<FakePush> openLoggedIn(WidgetTester tester) async {
    final session = MemorySessionStore();
    await session.saveToken('access:${FakeAuthApi.demoMobile}');
    final push = FakePush();
    usePhone(tester);
    await tester.pumpWidget(QboxApp(services: fakeServices(session: session, push: push)));
    await tester.pumpAndSettle();
    return push;
  }

  testWidgets('logged in: this phone gets push notifications; log out stops them', (tester) async {
    final push = await openLoggedIn(tester);
    expect(find.text('Choose Your Role'), findsOneWidget);
    expect(push.starts, 1);

    await tester.ensureVisible(find.byKey(const Key('log-out')));
    await tester.tap(find.byKey(const Key('log-out')));
    await tester.pumpAndSettle();
    expect(push.stops, 1);
  });

  testWidgets('tapping a notification opens that role\'s bell', (tester) async {
    final push = await openLoggedIn(tester);
    push.tap(QboxRole.business);
    await tester.pumpAndSettle();
    final bell = tester.widget<NoticesScreen>(find.byType(NoticesScreen));
    expect(bell.role, QboxRole.business);
    expect(push.opened.value, isNull);

    // From somewhere else in the app, another role's bell.
    push.tap(QboxRole.customer);
    await tester.pumpAndSettle();
    expect(tester.widget<NoticesScreen>(find.byType(NoticesScreen)).role, QboxRole.customer);
    Navigator.of(tester.element(find.byType(NoticesScreen))).pop();
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
    await tester.pumpAndSettle();
    expect(find.text('Choose Your Role'), findsOneWidget); // nothing piled up underneath
  });

  Future<void> openSettings(WidgetTester tester, FakePush push, QboxRole role) async {
    usePhone(tester);
    await tester.pumpWidget(QboxApp(services: fakeServices(push: push)));
    await tester.pumpAndSettle();
    final navigator = Navigator.of(tester.element(find.byType(Scaffold).first));
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => NoticeSettingsScreen(role: role))));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final found = find.byKey(Key(key));
    await tester.scrollUntilVisible(found, 200, scrollable: find.byType(Scrollable).last);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -150)); // clear of the bottom edge
    await tester.pumpAndSettle();
    await tester.ensureVisible(found);
    await tester.pumpAndSettle();
    await tester.tap(found);
    await tester.pumpAndSettle();
  }

  testWidgets('a shop chooses each kind said aloud', (tester) async {
    final push = FakePush();
    await openSettings(tester, push, QboxRole.business);
    for (final t in NoticeType.of(QboxRole.business)) {
      expect(find.byKey(Key('notice-speak-${t.code}')), findsOneWidget);
    }
    expect(find.byKey(const Key('notice-speak-tip')), findsNothing);
    await tapKey(tester, 'notice-speak-STOCK');
    await tapKey(tester, 'notice-speak-PAYMENT');
    expect(push.saved.spoken, {'BUSINESS:STOCK', 'BUSINESS:PAYMENT'});
    expect(find.byKey(const Key('notice-speak-tip')), findsOneWidget); // the battery tip
    await tapKey(tester, 'notice-speak-STOCK');
    expect(push.saved.spoken, {'BUSINESS:PAYMENT'});
  });

  testWidgets('a customer chooses its own kinds (udhaar, payments, budget)', (tester) async {
    final push = FakePush()..saved = const AlertPrefs(spoken: {'BUSINESS:PAYMENT'});
    await openSettings(tester, push, QboxRole.customer);
    expect(find.byKey(const Key('notice-speak-STOCK')), findsNothing);
    await tapKey(tester, 'notice-speak-UDHAAR');
    expect(push.saved.spoken, {'BUSINESS:PAYMENT', 'CUSTOMER:UDHAAR'}); // the shop's choice stays
  });

  testWidgets('choose a voice, after hearing it', (tester) async {
    final push = FakePush();
    final speaker = FakeSpeaker();
    usePhone(tester);
    await tester.pumpWidget(QboxApp(services: fakeServices(push: push, speaker: speaker)));
    await tester.pumpAndSettle();
    unawaited(Navigator.of(tester.element(find.byType(Scaffold).first))
        .push(MaterialPageRoute<void>(builder: (_) => const NoticeSettingsScreen(role: QboxRole.business))));
    await tester.pumpAndSettle();
    expect(find.text('Phone\'s usual voice'), findsOneWidget);
    await tapKey(tester, 'notice-voice');
    expect(find.text('Voice 1'), findsOneWidget);
    expect(find.text('Needs internet'), findsOneWidget); // Voice 2
    await tester.tap(find.byKey(const Key('voice-play-x-network-b')));
    await tester.pumpAndSettle();
    expect((speaker.said.last, speaker.voicesUsed.last), ('500 rupees received from Ravi', 'x-network-b'));
    await tester.tap(find.byKey(const Key('voice-x-local-a')));
    await tester.pumpAndSettle();
    expect(push.saved.voice, 'x-local-a');
    expect(find.text('Chosen voice'), findsOneWidget);
    await tapKey(tester, 'notice-voice');
    await tester.tap(find.byKey(const Key('voice-usual')));
    await tester.pumpAndSettle();
    expect(push.saved.voice, isNull);
  });

  testWidgets('quiet hours: off unless chosen, then any times', (tester) async {
    final push = FakePush();
    await openSettings(tester, push, QboxRole.business);
    expect(find.byKey(const Key('notice-quiet-from')), findsNothing);
    await tapKey(tester, 'notice-quiet');
    expect((push.saved.quietFrom, push.saved.quietTo), (22 * 60, 7 * 60));
    expect(find.text('10:00 PM'), findsOneWidget);
    expect(find.text('7:00 AM'), findsOneWidget);
    await tapKey(tester, 'notice-quiet-to');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(push.saved.quietTo, 7 * 60); // the picker opened at 7:00
    await tapKey(tester, 'notice-quiet');
    expect(push.saved.hasQuietHours, isFalse);
  });

  test('alert settings: saved, read back, and earlier test builds', () async {
    final settings = MemorySettingsStore();
    expect((await readAlertPrefs(settings)).spoken, isEmpty);
    const prefs = AlertPrefs(spoken: {'CUSTOMER:UDHAAR'}, quietFrom: 1320, quietTo: 420, voice: 'v1');
    await writeAlertPrefs(settings, prefs);
    final back = await readAlertPrefs(settings);
    expect(back.spoken, prefs.spoken);
    expect((back.quietFrom, back.quietTo, back.voice), (1320, 420, 'v1'));
    final old = MemorySettingsStore()..values['speak_money_alerts'] = '1';
    expect((await readAlertPrefs(old)).spoken, {'BUSINESS:PAYMENT', 'SUPPLIER:LEDGER'});
  });

  test('quiet hours and what is said', () {
    const prefs = AlertPrefs(spoken: {'CUSTOMER:UDHAAR'}, quietFrom: 22 * 60, quietTo: 7 * 60);
    expect([6, 7, 21, 22, 23].map((h) => prefs.isQuiet(h * 60)), [true, false, false, true, true]);
    const lunch = AlertPrefs(quietFrom: 13 * 60, quietTo: 14 * 60);
    expect([779, 780, 839, 840].map(lunch.isQuiet), [false, true, true, false]);
    expect(const AlertPrefs().isQuiet(600), isFalse);
    final udhaar = {'role': 'CUSTOMER', 'type': 'UDHAAR'};
    expect(shouldSpeak(prefs, udhaar, DateTime(2026, 11, 27, 12)), isTrue);
    expect(shouldSpeak(prefs, udhaar, DateTime(2026, 11, 27, 23)), isFalse); // quiet
    expect(shouldSpeak(prefs, {'role': 'BUSINESS', 'type': 'UDHAAR'}, DateTime(2026, 11, 27, 12)), isFalse);
  });

  test('what is said: money received, or only "says they paid"', () {
    final online = {'kind': 'PAID_ONLINE', 'name': 'Ravi', 'amount': '50000'};
    expect(spokenAlert(online, AppLanguage.english), '500 rupees received from Ravi');
    expect(spokenAlert(online, AppLanguage.telugu), 'Ravi నుండి 500 రూపాయలు వచ్చాయి');
    final says = {'kind': 'SAYS_PAID', 'name': 'Ravi', 'amount': '15050'};
    expect(spokenAlert(says, AppLanguage.english), 'Ravi says they paid 150.50 rupees. Please check');
    expect(spokenAlert(says, AppLanguage.hindi), 'Ravi ने कहा कि 150.50 रुपये भेजे हैं. जाँच लीजिए');
    expect(spokenAlert({...says, 'kind': 'CONFIRM_PAYMENT'}, AppLanguage.english), contains('says they paid'));
    for (final language in AppLanguage.values) {
      expect(spokenAlert(says, language), isNot(contains('received')));
    }
  });

  test('other alerts: common ones in every language, the rest in English', () {
    final credit = {'kind': 'CREDIT', 'name': 'Sri Balaji Kirana', 'amount': '10000', 'title': 'x'};
    expect(spokenAlert(credit, AppLanguage.english), 'Sri Balaji Kirana wrote 100 rupees udhaar');
    expect(spokenAlert(credit, AppLanguage.telugu), 'Sri Balaji Kirana 100 రూపాయల అప్పు రాశారు');
    final order = {'kind': 'NEW_ORDER', 'name': 'Ravi Stores', 'title': 'New order from Ravi Stores'};
    expect(spokenAlert(order, AppLanguage.hindi), 'Ravi Stores से नया ऑर्डर');
    final other = {'kind': 'ORDER_SENT', 'name': 'Ravi', 'title': 'Ravi: your goods are on the way'};
    expect(spokenAlert(other, AppLanguage.tamil), 'Ravi: your goods are on the way');
  });
}
