import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qbox_app/customer/expenses_screen.dart';
import 'package:qbox_app/customer/transactions_screen.dart';
import 'package:qbox_app/customer_home_screen.dart';
import 'package:qbox_app/onboarding_draft.dart';
import 'package:qbox_app/payments/payments_screen.dart';
import 'package:qbox_app/profile/notices.dart';
import 'package:qbox_app/profile/notices_screen.dart';
import 'package:qbox_app/services/app_services.dart';
import 'package:qbox_app/stock/stock_screen.dart';
import 'package:qbox_app/suppliers/suppliers_screen.dart';
import 'package:qbox_app/supplier_home_screen.dart';
import 'package:qbox_app/udhaar/my_udhaar_screen.dart';
import 'package:qbox_app/udhaar/udhaar_screen.dart';

import 'fake_auth_api.dart';
import 'udhaar_screen_test.dart' show tapKey;

final now = DateTime(2026, 11, 24, 15);

Notice notice(String kind, {String id = 'a', String name = 'Balaji', int? rupees, String? note, bool unread = true}) =>
    Notice(
      id: id,
      kind: kind,
      name: name,
      at: now,
      amountPaise: rupees == null ? null : rupees * 100,
      note: note,
      unread: unread,
    );

void main() {
  late FakeNoticesApi api;

  setUp(() => api = FakeNoticesApi());

  Future<void> open(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ServicesScope(
        services: fakeServices(notices: api),
        child: OnboardingScope(draft: OnboardingDraft(), child: MaterialApp(home: home)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder at(String key) => find.byKey(Key(key));

  test('every kind has words and opens its screen', () {
    final expected = <String, (String, String?, Type)>{
      'ADDED': ('Balaji added you to its udhaar book', null, MyUdhaarScreen),
      'CREDIT': ('Balaji wrote ₹250 udhaar', 'rice', MyUdhaarScreen),
      'RECORDED': ('Balaji recorded your payment of ₹250', 'rice', MyUdhaarScreen),
      'DELETED': ('Balaji deleted ₹250 from your udhaar', 'rice', MyUdhaarScreen),
      'NUMBER_KEPT': ('Balaji says this number is yours', 'Talk to the shop if it is not.', MyUdhaarScreen),
      'NUMBER_REMOVED': ('Balaji removed your number from its book', null, MyUdhaarScreen),
      'RECEIVED': ('Balaji received your ₹250', null, TransactionsScreen),
      'NOT_RECEIVED': ('Balaji did not receive ₹250', 'Check your UPI app, or talk to the shop.', TransactionsScreen),
      'BUDGET_NEAR': ('Most of this month\'s budget is used', '₹250 spent so far', ExpensesScreen),
      'BUDGET_OVER': ('You are over this month\'s budget', 'It was crossed at ₹250', ExpensesScreen),
      'PAID_ONLINE': ('Balaji paid ₹250 online', 'rice', PaymentsScreen),
      'SAYS_PAID': ('Balaji says they paid ₹250 by UPI', 'Check your bank, then confirm.', PaymentsScreen),
      'NOT_ME': ('Balaji: "This is not my number"', 'Please check and decide.', UdhaarScreen),
      'LOW_STOCK': ('Balaji is running low', '2.5 kg left', StockScreen),
      'SUPPLIER_DUE': ('Pay Balaji', '₹250 is due', SuppliersScreen),
    };
    for (final MapEntry(key: kind, value: (title, detail, screen)) in expected.entries) {
      final n = notice(
        kind,
        rupees: 250,
        note: kind == 'LOW_STOCK' ? '2500 KG' : (detail == 'rice' ? 'rice' : null),
      );
      expect((n.title, n.detail, n.screen.runtimeType), (title, detail, screen), reason: kind);
    }
  });

  test('reading what the server sends', () {
    final json = {
      'unread': 2,
      'off': ['BUDGET', 'SOMETHING_NEW'],
      'notices': [
        {'id': 'line-1', 'kind': 'CREDIT', 'name': 'Balaji', 'amountPaise': 100, 'at': '2026-11-24T09:00:00Z', 'unread': true},
        {'id': 'x', 'kind': 'SOMETHING_NEW', 'name': 'Balaji', 'at': '2026-11-24T09:00:00Z'},
        'bad',
      ],
    };
    final notices = Notices.fromJson(json)!;
    expect((notices.unread, notices.items.length), (2, 1));
    expect(notices.off, {NoticeType.budget});
    expect(notices.items.single.unread, isTrue);
    expect(Notices.fromJson('x'), isNull);
    expect(notice('LOW_STOCK', note: '2000 KG').left, '2 kg left');
    expect(notice('LOW_STOCK', note: '-500 L').left, '-0.5 l left');
    expect(notice('LOW_STOCK').left, '');
  });

  testWidgets('list: new ones marked; opening one reads it and opens its screen', (tester) async {
    api.items[QboxRole.customer] = [
      notice('CREDIT', id: 'a', rupees: 250, note: 'rice'),
      notice('ADDED', id: 'b', unread: false),
    ];
    await open(tester, NoticesScreen(role: QboxRole.customer, now: now));
    expect(find.text('1 new'), findsOneWidget);
    expect(at('notice-new-a'), findsOneWidget);
    expect(at('notice-new-b'), findsNothing);
    await tapKey(tester, 'notice-a');
    expect(find.byType(MyUdhaarScreen), findsOneWidget);
    expect(api.calls, contains('read a'));
    await tapKey(tester, 'udhaar-back');
    expect(at('notice-new-a'), findsNothing);
    expect(find.text('1 new'), findsNothing);
    expect(at('notices-read-all'), findsNothing);
  });

  testWidgets('mark all as read', (tester) async {
    api.items[QboxRole.business] = [notice('PAID_ONLINE', id: 'a', rupees: 5), notice('LOW_STOCK', id: 'b')];
    await open(tester, NoticesScreen(role: QboxRole.business, now: now));
    api.offline = true;
    await tapKey(tester, 'notices-read-all');
    expect(find.text('This needs internet. Please try again.'), findsOneWidget);
    api.offline = false;
    await tapKey(tester, 'notices-read-all');
    expect(at('notice-new-a'), findsNothing);
    expect(at('notice-new-b'), findsNothing);
  });

  testWidgets('empty, offline and retry', (tester) async {
    api.offline = true;
    await open(tester, NoticesScreen(role: QboxRole.customer, now: now));
    expect(find.text('Offline: notifications need internet.'), findsOneWidget);
    expect(at('notices-empty'), findsNothing);
    api.offline = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(at('notices-empty'), findsOneWidget);
  });

  testWidgets('choosing notifications; put back when it could not be saved', (tester) async {
    await open(tester, NoticesScreen(role: QboxRole.customer, now: now));
    await tapKey(tester, 'notices-settings');
    expect(find.byWidgetPredicate((w) => w is SwitchListTile && '${w.key}'.contains('notice-type-')), findsNWidgets(3));
    await tapKey(tester, 'notice-type-BUDGET');
    expect(api.off[QboxRole.customer], {NoticeType.budget});
    api.offline = true;
    await tapKey(tester, 'notice-type-UDHAAR');
    expect(tester.widget<SwitchListTile>(at('notice-type-UDHAAR')).value, isTrue);
    expect(tester.widget<SwitchListTile>(at('notice-type-BUDGET')).value, isFalse);
  });

  testWidgets('home: the count, hidden at zero, read again on coming back', (tester) async {
    api.items[QboxRole.customer] = [for (var i = 0; i < 12; i++) notice('ADDED', id: 'n$i')];
    await open(tester, const CustomerHomeScreen());
    expect(tester.widget<Text>(at('home-unread')).data, '9+');
    await tapKey(tester, 'home-bell');
    await tapKey(tester, 'notices-read-all');
    await tapKey(tester, 'udhaar-back');
    expect(at('home-unread'), findsNothing);
    api.items[QboxRole.customer] = [notice('ADDED')];
    await tester.pump(const Duration(minutes: 1, seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(at('home-unread')).data, '1');
    api.offline = true; // the last count stays
    await tester.pump(const Duration(minutes: 1, seconds: 1));
    await tester.pumpAndSettle();
    expect(at('home-unread'), findsOneWidget);
  });

  testWidgets('not asked while another screen is open', (tester) async {
    await open(tester, const CustomerHomeScreen());
    await tapKey(tester, 'home-profile');
    final before = api.calls.length;
    await tester.pump(const Duration(minutes: 3));
    expect(api.calls.length, before);
    await tapKey(tester, 'udhaar-back');
    expect(api.calls.last, 'unread customer');
    expect(api.calls.length, before + 1);
  });

  testWidgets('supplier: an empty bell, and what to be told', (tester) async {
    await open(tester, const SupplierHomeScreen());
    await tapKey(tester, 'home-bell');
    expect(at('notices-empty'), findsOneWidget);
    await tapKey(tester, 'notices-settings');
    expect(find.byWidgetPredicate((w) => w is SwitchListTile && '${w.key}'.contains('notice-type-')), findsNWidgets(3));
  });
}
