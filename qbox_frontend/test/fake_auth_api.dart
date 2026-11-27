import 'package:qbox_app/calculator/calculator_store.dart';
import 'package:qbox_app/calculator/voice_services.dart';
import 'package:qbox_app/calendar/calendar_api.dart';
import 'package:qbox_app/calendar/calendar_models.dart';
import 'package:qbox_app/calendar/calendar_repository.dart';
import 'package:qbox_app/calendar/calendar_store.dart';
import 'package:qbox_app/calendar/reminders.dart';
import 'package:qbox_app/customer/pages_repository.dart';
import 'package:qbox_app/customer/transactions_repository.dart';
import 'package:qbox_app/models/qbox_user.dart';
import 'package:qbox_app/onboarding_draft.dart';
import 'package:qbox_app/payments/checkout.dart';
import 'package:qbox_app/payments/payments_api.dart';
import 'package:qbox_app/profile/notices.dart';
import 'package:qbox_app/profile/photos.dart';
import 'package:qbox_app/profile/profile_api.dart';
import 'package:qbox_app/services/app_services.dart';
import 'package:qbox_app/services/auth_api.dart';
import 'package:qbox_app/services/device_actions.dart';
import 'package:qbox_app/services/language_api.dart';
import 'package:qbox_app/services/push_notifications.dart';
import 'package:qbox_app/services/session_store.dart';
import 'package:qbox_app/services/settings_store.dart';
import 'package:qbox_app/stock/stock_api.dart';
import 'package:qbox_app/stock/stock_repository.dart';
import 'package:qbox_app/stock/stock_store.dart';
import 'package:qbox_app/suppliers/supplier_api.dart';
import 'package:qbox_app/suppliers/supplier_repository.dart';
import 'package:qbox_app/supply/supply_repository.dart';
import 'package:qbox_app/translator/languages.dart';
import 'package:qbox_app/translator/translation_service.dart';
import 'package:qbox_app/udhaar/udhaar_api.dart';
import 'package:qbox_app/udhaar/udhaar_models.dart';
import 'package:qbox_app/udhaar/udhaar_repository.dart';
import 'package:qbox_app/udhaar/udhaar_store.dart';

import 'fake_notices.dart';
import 'fake_pages.dart';
import 'fake_payments.dart';
import 'fake_profile.dart';
import 'fake_stock.dart';
import 'fake_suppliers.dart';
import 'fake_supply.dart';
import 'fake_transactions.dart';

export 'fake_notices.dart';
export 'fake_pages.dart';
export 'fake_payments.dart';
export 'fake_profile.dart';
export 'fake_stock.dart';
export 'fake_suppliers.dart';
export 'fake_supply.dart';
export 'fake_transactions.dart';

/// A pretend backend for widget tests. It follows the same rules as the
/// FastAPI one: the OTP is always 123456, a mobile can register once,
/// and login needs the right PIN.
class FakeAuthApi implements AuthApi {
  FakeAuthApi() {
    _accounts[demoMobile] = _Account(
      pin: demoPin,
      user: const QboxUser(
        id: 1,
        mobile: demoMobile,
        roles: {QboxRole.business, QboxRole.customer, QboxRole.supplier},
        shop: ShopProfile(qboxId: 'QBM10001', shopName: 'Sri Rama Kirana'),
        customer: CustomerProfile(qboxId: 'QBC10001', fullName: 'Ramu'),
        supplier: SupplierProfile(
          qboxId: 'QBS10001',
          supplierName: 'Sri Venkateswara Suppliers',
        ),
      ),
    );
  }

  static const demoMobile = '9123456789';
  static const demoPin = '1234';
  static const otp = '123456';

  final Map<String, _Account> _accounts = {};
  Map<String, dynamic>? lastRegistration;

  /// When true, [me] fails as if the server could not be reached.
  bool offline = false;

  @override
  Future<OtpSent> sendOtp(String mobile, OtpPurpose purpose) async {
    final registered = _accounts.containsKey(mobile);
    if (purpose == OtpPurpose.signup && registered) {
      throw const ApiException(
        'MOBILE_REGISTERED',
        'This mobile number is already registered. Please log in',
        status: 409,
      );
    }
    if (purpose == OtpPurpose.resetPin && !registered) {
      throw const ApiException(
        'MOBILE_NOT_FOUND',
        'No QBOX account found for this mobile number',
        status: 404,
      );
    }
    return const OtpSent(resendInSeconds: 30, devOtp: otp);
  }

  @override
  Future<String> verifyOtp(
    String mobile,
    OtpPurpose purpose,
    String code,
  ) async {
    if (code != otp) {
      throw const ApiException(
        'OTP_WRONG',
        'Wrong OTP. Please check and try again',
        status: 400,
      );
    }
    return 'verify:${purpose.code}:$mobile';
  }

  @override
  Future<AuthResult> register(Map<String, dynamic> body) async {
    lastRegistration = body;
    final mobile = _mobileFrom(
      body['verificationToken'] as String,
      OtpPurpose.signup,
    );
    final id = _accounts.length + 1;
    final roles = {
      for (final code in body['roles'] as List<dynamic>)
        roleFromCode(code as String)!,
    };
    final shop = body['shop'] as Map<String, dynamic>?;
    final customer = body['customer'] as Map<String, dynamic>?;
    final supplier = body['supplier'] as Map<String, dynamic>?;
    final user = QboxUser(
      id: id,
      mobile: mobile,
      roles: roles,
      shop: shop == null
          ? null
          : ShopProfile(
              qboxId: 'QBM${10000 + id}',
              shopName: shop['shopName'] as String,
            ),
      customer: customer == null
          ? null
          : CustomerProfile(
              qboxId: 'QBC${10000 + id}',
              fullName: customer['fullName'] as String,
            ),
      supplier: supplier == null
          ? null
          : SupplierProfile(
              qboxId: 'QBS${10000 + id}',
              supplierName: supplier['supplierName'] as String,
            ),
    );
    _accounts[mobile] = _Account(pin: body['pin'] as String, user: user);
    return AuthResult(accessToken: 'access:$mobile', user: user);
  }

  @override
  Future<AuthResult> login(String mobile, String pin) async {
    final account = _accounts[mobile];
    if (account == null || account.pin != pin) {
      throw const ApiException(
        'LOGIN_FAILED',
        'Mobile number or PIN does not match',
        status: 401,
      );
    }
    return AuthResult(accessToken: 'access:$mobile', user: account.user);
  }

  @override
  Future<void> resetPin(String verificationToken, String newPin) async {
    final mobile = _mobileFrom(verificationToken, OtpPurpose.resetPin);
    final account = _accounts[mobile]!;
    _accounts[mobile] = _Account(pin: newPin, user: account.user);
  }

  @override
  Future<QboxUser> me(String accessToken) async {
    if (offline) {
      throw const ApiException(
        'NETWORK',
        'Cannot reach the QBOX server. Check your internet connection.',
      );
    }
    final account = _accounts[accessToken.replaceFirst('access:', '')];
    if (account == null) {
      throw const ApiException('TOKEN_INVALID', 'Please log in', status: 401);
    }
    return account.user;
  }

  String _mobileFrom(String token, OtpPurpose purpose) {
    final prefix = 'verify:${purpose.code}:';
    if (!token.startsWith(prefix)) {
      throw const ApiException(
        'TOKEN_INVALID',
        'Please verify your mobile again',
        status: 401,
      );
    }
    return token.substring(prefix.length);
  }
}

class _Account {
  const _Account({required this.pin, required this.user});

  final String pin;
  final QboxUser user;
}

/// Pretend microphone: returns [nextWords] (or throws [nextError]).
class FakeVoiceInput implements VoiceInput {
  String nextWords = '';

  /// Said one after another, before [nextWords].
  final List<String> queue = [];
  VoiceException? nextError;
  VoicePace? lastPace;
  int listenCount = 0;

  /// The language it was last asked to listen in.
  String? lastLocale;

  @override
  Future<String> listen({
    required void Function(String words) onWords,
    String localeId = 'en_IN',
    VoicePace pace = const VoicePace(),
    void Function()? onReady,
  }) async {
    listenCount++;
    lastLocale = localeId;
    lastPace = pace;
    final error = nextError;
    if (error != null) throw error;
    onReady?.call();
    final words = queue.isEmpty ? nextWords : queue.removeAt(0);
    onWords(words);
    return words;
  }

  @override
  Future<void> stop() async {}
}

/// Pretend speaker: remembers what it was asked to say, and in which voice.
class FakeSpeaker implements Speaker, VoiceChoices {
  final List<String> said = [];
  final List<String> locales = [];

  /// The pretend phone's voices for every language, and the voice each line used.
  List<String> phoneVoices = const ['x-local-a', 'x-network-b'];
  final List<String?> voicesUsed = [];

  @override
  Future<List<String>> voices(String locale) async => phoneVoices;

  @override
  Future<void> sayWith(String text, {required String locale, required String voice}) async {
    said.add(text);
    locales.add(locale);
    voicesUsed.add(voice);
  }

  /// Voices this pretend phone does NOT have.
  final Set<String> missingVoices = {};

  @override
  Future<void> say(String text, {String locale = 'en-IN'}) async {
    said.add(text);
    locales.add(locale);
    voicesUsed.add(null);
  }

  @override
  Future<bool> hasVoice(String locale) async => !missingVoices.contains(locale);

  @override
  Future<void> stop() async => stops++;

  int stops = 0;
}

AppServices fakeServices({
  FakeAuthApi? api,
  SessionStore? session,
  CalculatorStore? calculator,
  VoiceInput? voice,
  Speaker? speaker,
  CalendarApi? calendar,
  CalendarStore? calendarStore,
  ReminderScheduler? reminders,
  UdhaarApi? udhaar,
  UdhaarStore? udhaarStore,
  DeviceActions? device,
  TextTranslator? translator,
  SettingsStore? settings,
  PaymentsApi? payments,
  Checkout? checkout,
  StockApi? stock,
  StockStore? stockStore,
  SupplierApi? suppliers,
  SupplierStore? supplierStore,
  TransactionsApi? transactions,
  TransactionsStore? transactionsStore,
  PagesApi? pages,
  PagesStore? pagesStore,
  ProfileApi? profile,
  PhotoPicker? photoPicker,
  PhotoStore? photoStore,
  NoticesApi? notices,
  SupplyApi? supply,
  SupplyStore? supplyStore,
  PushNotifications? push,
}) {
  final profileApi = profile ?? FakeProfileApi();
  final calendarCopy = calendarStore ?? MemoryCalendarStore();
  final reminderList = reminders ?? FakeReminders();
  return AppServices(
    auth: api ?? FakeAuthApi(),
    session: session ?? MemorySessionStore(),
    calculator: calculator ?? MemoryCalculatorStore(),
    voice: voice ?? FakeVoiceInput(),
    speaker: speaker ?? FakeSpeaker(),
    calendar: CalendarRepository(calendar ?? FakeCalendarApi(), calendarCopy, reminderList),
    calendarStore: calendarCopy,
    reminders: reminderList,
    udhaar: UdhaarRepository(
      udhaar ?? FakeUdhaarApi(),
      udhaarStore ?? MemoryUdhaarStore(),
    ),
    device: device ?? FakeDeviceActions(),
    translator: translator ?? FakeTranslator(),
    settings: settings ?? MemorySettingsStore(),
    payments: payments ?? FakePaymentsApi(),
    checkout: checkout ?? FakeCheckout(),
    stock: StockRepository(stock ?? FakeStockApi(), stockStore ?? MemoryStockStore()),
    suppliers: SupplierRepository(suppliers ?? FakeSupplierApi(), supplierStore ?? MemorySupplierStore()),
    transactions: TransactionsRepository(
      transactions ?? FakeTransactionsApi(),
      transactionsStore ?? MemoryTransactionsStore(),
    ),
    pages: PagesRepository(pages ?? FakePagesApi(), pagesStore ?? MemoryPagesStore()),
    profile: profileApi,
    photos: PhotoRepository(profileApi, photoStore ?? MemoryPhotoStore()),
    photoPicker: photoPicker ?? FakePhotoPicker(),
    notices: notices ?? FakeNoticesApi(),
    supply: SupplyRepository(supply ?? FakeSupplyApi(), supplyStore ?? MemorySupplyStore()),
    push: push,
  );
}

/// Pretend on-phone translator: answers from [phrases] (keyed by
/// "from>to:text"), else returns "[to] text". Language packs can be missing.
class FakeTranslator implements TextTranslator {
  final Map<String, String> phrases = {};
  final Set<AppLanguage> downloaded = {...AppLanguage.values};
  final List<AppLanguage> downloads = [];
  bool failDownloads = false;
  TranslateException? error;

  @override
  Future<bool> isReady(AppLanguage language) async => downloaded.contains(language);

  @override
  Future<bool> download(AppLanguage language) async {
    downloads.add(language);
    if (failDownloads) return false;
    downloaded.add(language);
    return true;
  }

  @override
  Future<String> translate(String text, {required AppLanguage from, required AppLanguage to, bool fast = false}) async {
    if (from == to) return text;
    final e = error;
    if (e != null) throw e;
    for (final l in {from, to}) {
      if (!downloaded.contains(l)) {
        throw TranslateException(
          'No internet, and the ${l.englishName} offline pack is not downloaded yet.',
          needsPack: true,
        );
      }
    }
    return phrases['${from.code}>${to.code}:$text'] ?? '[${to.code}] $text';
  }
}

/// Pretend QBOX language server (IndicConformer + IndicTrans2).
class FakeLanguageApi implements LanguageApi {
  ApiException? error;
  int translateCalls = 0;
  String heard = '';
  bool? lastFast;
  int heardClips = 0;
  int lastClip = 0;

  /// What is heard when [heard] is not set.
  final String speechText = 'బియ్యం';
  String? lastAudio;
  bool online = true;
  int statusCalls = 0;

  @override
  Future<bool> isOnline() async {
    statusCalls++;
    return online;
  }

  @override
  Future<String> translate(String text, {required String from, required String to, bool fast = false}) async {
    translateCalls++;
    lastFast = fast;
    final e = error;
    if (e != null) throw e;
    return 'online[$from>$to] $text';
  }

  @override
  Future<String> speechToText(String wavBase64, {required String language, int samplingRate = 16000}) async {
    lastAudio = wavBase64;
    heardClips++;
    lastClip = wavBase64.length * 3 ~/ 4;
    final e = error;
    if (e != null) throw e;
    return heard.isEmpty ? speechText : heard;
  }
}

/// Pretend phone: remembers links it was asked to open; returns [nextContact].
class FakeDeviceActions implements DeviceActions {
  int settingsOpened = 0;
  int voiceSettingsOpened = 0;
  int? volume = 60;
  int? build = 1;

  @override
  Future<int?> appBuild() async => build;

  @override
  Future<bool> openVoiceSettings() async {
    voiceSettingsOpened++;
    return true;
  }

  @override
  Future<int?> mediaVolume() async => volume;

  @override
  Future<bool> openAppSettings() async {
    settingsOpened++;
    return true;
  }

  final List<Uri> opened = [];
  PickedContact? nextContact;

  /// Links with this scheme fail to open (e.g. 'whatsapp' = app not installed).
  String? failScheme;

  @override
  Future<bool> openLink(Uri uri) async {
    opened.add(uri);
    return uri.scheme != failScheme;
  }

  @override
  Future<PickedContact?> pickContact() async => nextContact;
}

/// Pretend udhaar server with the same rules as the FastAPI one: the add-
/// customer code is always 123456, balances come from live entries, the same
/// clientRef is kept once, deleted entries stay with a reason.
class FakeUdhaarApi implements UdhaarApi {
  static const otp = '123456';

  final Map<int, UdhaarCustomer> customers = {};
  final Map<int, List<UdhaarEntry>> entries = {};
  final List<MyBook> books = [];
  final Map<int, List<UdhaarEntry>> bookEntries = {};
  final List<String> invitesSentTo = [];
  bool offline = false;
  int _nextId = 1;

  void _check() {
    if (offline) {
      throw const ApiException(
        'NETWORK',
        'Cannot reach the QBOX server. Check your internet connection.',
      );
    }
  }

  /// Adds a customer directly (test setup).
  UdhaarCustomer seed(String name, String mobile, {int? limitPaise, List<UdhaarEntry> history = const []}) {
    final c = UdhaarCustomer(
      id: _nextId++,
      name: name,
      mobile: mobile,
      creditLimitPaise: limitPaise,
    );
    customers[c.id] = c;
    entries[c.id] = List.of(history);
    return _withBalance(c);
  }

  /// The customer reported "not me" (test setup for the shop side).
  void report(int customerId) => _setDispute(customerId, Dispute.reported);

  UdhaarCustomer _setDispute(int id, Dispute dispute, {String? mobile}) {
    final c = customers[id]!;
    customers[id] = UdhaarCustomer(
      id: id,
      name: c.name,
      mobile: mobile ?? c.mobile,
      creditLimitPaise: c.creditLimitPaise,
      dispute: dispute,
      disputedAt: dispute == Dispute.reported ? DateTime(2026, 11, 19, 11) : c.disputedAt,
    );
    return _withBalance(customers[id]!);
  }

  MyBook _setBookDispute(int bookId, Dispute dispute) {
    final i = books.indexWhere((b) => b.bookId == bookId);
    final b = books[i];
    return books[i] = MyBook(
      bookId: b.bookId,
      shopName: b.shopName,
      shopPhone: b.shopPhone,
      shopCategory: b.shopCategory,
      shopAddress: b.shopAddress,
      balancePaise: b.balancePaise,
      lastEntryAt: b.lastEntryAt,
      dispute: dispute,
      verifiedAt: b.verifiedAt,
    );
  }

  UdhaarCustomer _withBalance(UdhaarCustomer c) {
    final list = entries[c.id] ?? const [];
    var balance = 0;
    DateTime? last;
    DateTime? lastPaid;
    DateTime? firstCredit;
    for (final e in list.where((e) => !e.deleted)) {
      balance += e.effect;
      if (last == null || e.entryAt.isAfter(last)) last = e.entryAt;
      if (e.kind == EntryKind.payment && (lastPaid == null || e.entryAt.isAfter(lastPaid))) {
        lastPaid = e.entryAt;
      }
      if (e.kind == EntryKind.credit && (firstCredit == null || e.entryAt.isBefore(firstCredit))) {
        firstCredit = e.entryAt;
      }
    }
    return UdhaarCustomer(
      id: c.id,
      name: c.name,
      mobile: c.mobile,
      creditLimitPaise: c.creditLimitPaise,
      balancePaise: balance,
      lastEntryAt: last,
      owingSince: balance > 0 ? (lastPaid ?? firstCredit) : null,
      dispute: c.dispute,
      disputedAt: c.disputedAt,
    );
  }

  List<UdhaarEntry> _sorted(int id) =>
      List.of(entries[id] ?? const <UdhaarEntry>[])..sort((a, b) => b.entryAt.compareTo(a.entryAt));

  @override
  Future<UdhaarBook> book() async {
    _check();
    final list = customers.values.map(_withBalance).toList()
      ..sort((a, b) => b.balancePaise.compareTo(a.balancePaise));
    return UdhaarBook(list);
  }

  @override
  Future<InviteSent> sendInvite(String name, String mobile) async {
    _check();
    if (customers.values.any((c) => c.mobile == mobile)) {
      throw ApiException('CUSTOMER_EXISTS', '$name is already in your udhaar book with this number',
          status: 409);
    }
    invitesSentTo.add(mobile);
    return const InviteSent(resendInSeconds: 30, devOtp: otp);
  }

  @override
  Future<UdhaarCustomer> addCustomer({
    required String name,
    required String mobile,
    required String otp,
    int? creditLimitPaise,
  }) async {
    _check();
    if (otp != FakeUdhaarApi.otp) {
      throw const ApiException('OTP_WRONG', 'Wrong OTP. Please check and try again', status: 400);
    }
    return seed(name, mobile, limitPaise: creditLimitPaise);
  }

  @override
  Future<CustomerDetail> customer(int id) async {
    _check();
    return CustomerDetail(customer: _withBalance(customers[id]!), entries: _sorted(id));
  }

  @override
  Future<UdhaarCustomer> changeCustomer(int id, {required String name, int? creditLimitPaise}) async {
    _check();
    final old = customers[id]!;
    customers[id] = UdhaarCustomer(
      id: id,
      name: name,
      mobile: old.mobile,
      creditLimitPaise: creditLimitPaise,
    );
    return _withBalance(customers[id]!);
  }

  @override
  Future<UdhaarEntry> addEntry(int customerId, EntryDraft draft) async {
    _check();
    final list = entries[customerId]!;
    final existing = list.where((e) => e.clientRef == draft.clientRef).firstOrNull;
    if (existing != null) return existing;
    final entry = UdhaarEntry(
      id: _nextId++,
      kind: draft.kind,
      amountPaise: draft.amountPaise,
      entryAt: draft.entryAt,
      clientRef: draft.clientRef,
      note: draft.note.trim().isEmpty ? null : draft.note.trim(),
    );
    list.add(entry);
    return entry;
  }

  @override
  Future<UdhaarEntry> deleteEntry(int entryId, String reason) async {
    _check();
    for (final list in entries.values) {
      final i = list.indexWhere((e) => e.id == entryId);
      if (i < 0) continue;
      final e = list[i];
      list[i] = UdhaarEntry(
        id: e.id,
        kind: e.kind,
        amountPaise: e.amountPaise,
        entryAt: e.entryAt,
        clientRef: e.clientRef,
        note: e.note,
        deletedAt: DateTime(2026, 11, 19, 16),
        deleteReason: reason,
      );
      return list[i];
    }
    throw const ApiException('ENTRY_NOT_FOUND', 'This entry no longer exists', status: 404);
  }

  @override
  Future<List<MyBook>> myBooks() async {
    _check();
    return books.where((b) => b.dispute != Dispute.unlinked).toList();
  }

  @override
  Future<MyBookDetail> myBook(int bookId) async {
    _check();
    final book = books.firstWhere((b) => b.bookId == bookId);
    return MyBookDetail(book: book, entries: bookEntries[bookId] ?? const []);
  }

  @override
  Future<MyBook> notMe(int bookId) async {
    _check();
    final book = books.firstWhere((b) => b.bookId == bookId);
    if (book.dispute == Dispute.confirmed) {
      throw const ApiException('DISPUTE_CLOSED',
          'The shop already confirmed this number is yours. Please talk to the shop', status: 409);
    }
    return book.dispute == Dispute.none ? _setBookDispute(bookId, Dispute.reported) : book;
  }

  @override
  Future<MyBook> cancelNotMe(int bookId) async {
    _check();
    final book = books.firstWhere((b) => b.bookId == bookId);
    return book.dispute == Dispute.reported ? _setBookDispute(bookId, Dispute.none) : book;
  }

  @override
  Future<UdhaarCustomer> confirmDispute(int customerId) async => _decide(customerId, Dispute.confirmed);

  @override
  Future<UdhaarCustomer> unlinkDispute(int customerId) async => _decide(customerId, Dispute.unlinked);

  UdhaarCustomer _decide(int id, Dispute decision) {
    _check();
    if (customers[id]!.dispute != Dispute.reported) {
      throw const ApiException('NO_DISPUTE', 'There is no report to check for this customer', status: 409);
    }
    return _setDispute(id, decision);
  }

  @override
  Future<InviteSent> sendNumberInvite(int customerId, String mobile) async {
    _check();
    invitesSentTo.add(mobile);
    return const InviteSent(resendInSeconds: 30, devOtp: otp);
  }

  @override
  Future<UdhaarCustomer> changeNumber(int customerId, String mobile, String code) async {
    _check();
    if (code != otp) {
      throw const ApiException('OTP_WRONG', 'Wrong OTP. Please check and try again', status: 400);
    }
    return _setDispute(customerId, Dispute.none, mobile: mobile);
  }
}

/// Pretend calendar server: keeps events in memory, per role.
class FakeCalendarApi implements CalendarApi {
  final Map<QboxRole, List<CalendarEvent>> saved = {};
  List<Festival> festivalList = [
    Festival(day: DateTime(2026, 11, 8), name: 'Deepavali', telugu: false),
    Festival(
      day: DateTime(2026, 11, 24),
      name: 'Kartika Purnima',
      telugu: false,
    ),
  ];
  bool offline = false;

  /// The next event is saved, but the answer does not come back.
  bool loseAnswer = false;
  final Map<String?, int> _refs = {};
  int _nextId = 1;

  void _check() {
    if (offline) {
      throw const ApiException(
        'NETWORK',
        'Cannot reach the QBOX server. Check your internet connection.',
      );
    }
  }

  CalendarEvent _make(int id, EventDraft d) => CalendarEvent(
    id: id,
    title: d.title.trim(),
    day: d.day,
    minuteOfDay: d.minuteOfDay,
    category: d.category,
    repeat: d.repeat,
    remindMinutes: d.remindMinutes,
    note: d.note,
  );

  @override
  Future<List<CalendarEvent>> events(QboxRole role) async {
    _check();
    return List.of(saved[role] ?? const []);
  }

  @override
  Future<CalendarEvent> create(QboxRole role, EventDraft draft, {String? ref}) async {
    _check();
    final before = _refs[ref];
    if (before != null) return saved[role]!.firstWhere((e) => e.id == before);
    final event = _make(_nextId++, draft);
    (saved[role] ??= []).add(event);
    if (ref != null) _refs[ref] = event.id;
    if (loseAnswer) {
      loseAnswer = false;
      throw const ApiException('NETWORK', 'No answer');
    }
    return event;
  }

  @override
  Future<CalendarEvent> update(QboxRole role, int id, EventDraft draft) async {
    _check();
    final list = saved[role]!;
    final i = list.indexWhere((e) => e.id == id);
    list[i] = _make(id, draft);
    return list[i];
  }

  @override
  Future<void> delete(int id) async {
    _check();
    for (final list in saved.values) {
      list.removeWhere((e) => e.id == id);
    }
  }

  @override
  Future<List<Festival>> festivals() async {
    _check();
    return festivalList;
  }
}

/// Pretend notifications: remembers what would have been scheduled.
class FakeReminders implements ReminderScheduler {
  final Map<QboxRole, List<CalendarEvent>> synced = {};
  bool cleared = false;
  int permissionAsks = 0;
  ReminderProblem now = ReminderProblem.none;
  int exactAsks = 0;

  @override
  Future<ReminderProblem> problem() async => now;

  @override
  Future<void> askExactTime() async {
    exactAsks++;
    now = ReminderProblem.none;
  }

  @override
  Future<bool> askPermission() async {
    permissionAsks++;
    return true;
  }

  @override
  Future<void> sync(QboxRole role, List<CalendarEvent> events) async =>
      synced[role] = List.of(events);

  @override
  Future<void> clearAll() async {
    cleared = true;
    synced.clear();
  }

  /// Notifications shown straight away: "title: body".
  final List<String> shown = [];

  @override
  Future<void> showNow({required int id, required String title, required String body}) async =>
      shown.add('$title: $body');

  /// Supplier pay-by reminders set: "day: title".
  List<String> dues = [];

  @override
  Future<void> syncDues(List<DueReminder> list) async =>
      dues = [for (final d in list) '${d.day.year}-${d.day.month}-${d.day.day}: ${d.title}'];
}
