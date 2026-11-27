import '../translator/languages.dart';
import '../udhaar/udhaar_models.dart' show rupees;

/// How the shop takes payments.
class PaymentSettings {
  const PaymentSettings({
    this.upiId,
    this.upiName,
    this.razorpayConnected = false,
    this.razorpayKeyHint,
    this.automatic = false,
    this.testMode = false,
    this.usingTestAccount = false,
  });

  /// The shop's own UPI ID (payments to it are confirmed by hand).
  final String? upiId;
  final String? upiName;

  /// The shop's own Razorpay account is connected.
  final bool razorpayConnected;
  final String? razorpayKeyHint;

  /// Payments are confirmed by themselves ("₹250 received").
  final bool automatic;

  /// Pretend money only (Razorpay test keys).
  final bool testMode;

  /// Using QBOX's test account (development only).
  final bool usingTestAccount;

  bool get hasUpi => (upiId ?? '').isNotEmpty;

  /// Some way to take a payment is set up.
  bool get canCollect => automatic || hasUpi;

  static PaymentSettings? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    return PaymentSettings(
      upiId: json['upiId'] as String?,
      upiName: json['upiName'] as String?,
      razorpayConnected: json['razorpayConnected'] == true,
      razorpayKeyHint: json['razorpayKeyHint'] as String?,
      automatic: json['automatic'] == true,
      testMode: json['testMode'] == true,
      usingTestAccount: json['usingTestAccount'] == true,
    );
  }
}

enum PaymentSource {
  counter('COUNTER', 'UPI QR'),
  udhaar('UDHAAR', 'Udhaar paid in QBOX'),
  manual('MANUAL', 'UPI (confirmed by you)'),
  direct('DIRECT', 'Paid from QBOX');

  const PaymentSource(this.code, this.label);

  final String code;
  final String label;

  static PaymentSource fromCode(Object? code) =>
      values.firstWhere((s) => s.code == code, orElse: () => PaymentSource.counter);
}

enum PaymentStatus {
  waiting('WAITING'),
  paid('PAID'),
  expired('EXPIRED'),
  cancelled('CANCELLED');

  const PaymentStatus(this.code);

  final String code;

  static PaymentStatus fromCode(Object? code) =>
      values.firstWhere((s) => s.code == code, orElse: () => PaymentStatus.waiting);
}

class Payment {
  const Payment({
    required this.id,
    required this.amountPaise,
    this.source = PaymentSource.counter,
    this.status = PaymentStatus.waiting,
    this.note,
    this.udhaarCustomerId,
    this.customerName,
    this.payerVpa,
    this.method,
    this.qrImageUrl,
    this.payUrl,
    this.testMode = false,
    this.expiresAt,
    this.paidAt,
    this.claimedAt,
    this.createdAt,
  });

  final int id;
  final int amountPaise;
  final PaymentSource source;
  final PaymentStatus status;
  final String? note;
  final int? udhaarCustomerId;
  final String? customerName;

  /// The UPI ID the money came from (e.g. ramesh@okaxis).
  final String? payerVpa;
  final String? method;

  /// A ready QR picture from Razorpay, or a payment page to draw as a QR.
  final String? qrImageUrl;
  final String? payUrl;
  final bool testMode;
  final DateTime? expiresAt;
  final DateTime? paidAt;

  /// UPI (Pay to Shop): when the customer said they paid; the shop confirms.
  final DateTime? claimedAt;
  final DateTime? createdAt;

  bool get isPaid => status == PaymentStatus.paid;

  /// Who paid, as well as QBOX knows: the udhaar customer, or their UPI ID.
  String? get payer => customerName ?? payerVpa;

  static Payment? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final amount = json['amountPaise'];
    if (id is! int || amount is! int) return null;
    return Payment(
      id: id,
      amountPaise: amount,
      source: PaymentSource.fromCode(json['source']),
      status: PaymentStatus.fromCode(json['status']),
      note: json['note'] as String?,
      udhaarCustomerId: json['udhaarCustomerId'] as int?,
      customerName: json['customerName'] as String?,
      payerVpa: json['payerVpa'] as String?,
      method: json['method'] as String?,
      qrImageUrl: json['qrImageUrl'] as String?,
      payUrl: json['payUrl'] as String?,
      testMode: json['testMode'] == true,
      expiresAt: _time(json['expiresAt']),
      paidAt: _time(json['paidAt']),
      claimedAt: _time(json['claimedAt']),
      createdAt: _time(json['createdAt']),
    );
  }
}

/// Everything paid to the shop on one day.
class PaymentsDay {
  const PaymentsDay({required this.totalPaise, required this.payments, this.toConfirm = const []});

  final int totalPaise;
  final List<Payment> payments;

  /// UPI payments customers say they made; the shop checks its bank.
  final List<Payment> toConfirm;

  static PaymentsDay? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final list = json['payments'];
    if (list is! List) return null;
    return PaymentsDay(
      totalPaise: json['totalPaise'] as int? ?? 0,
      payments: list.map(Payment.fromJson).whereType<Payment>().toList(),
      toConfirm: [for (final p in json['toConfirm'] as List? ?? const []) ?Payment.fromJson(p)],
    );
  }
}

/// What the app needs to open Razorpay's payment screen.
class UdhaarPayStart {
  const UdhaarPayStart({
    required this.payment,
    required this.keyId,
    required this.orderId,
    required this.shopName,
    required this.contact,
    this.description = 'Udhaar payment',
  });

  final Payment payment;
  final String keyId;
  final String orderId;
  final String shopName;
  final String contact;
  final String description;

  static UdhaarPayStart? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final payment = Payment.fromJson(json['payment']);
    final key = json['keyId'];
    final order = json['orderId'];
    if (payment == null || key is! String || order is! String) return null;
    return UdhaarPayStart(
      payment: payment,
      keyId: key,
      orderId: order,
      shopName: json['shopName'] as String? ?? 'Shop',
      contact: json['contact'] as String? ?? '',
    );
  }
}

/// A shop the customer can pay ("Pay to Shop").
class PayShop {
  const PayShop({
    required this.ref,
    required this.shopName,
    this.shopCategory,
    this.shopPhoto,
    this.bookId,
    this.duePaise = 0,
    this.online = false,
    this.testMode = false,
    this.upi = false,
  });

  /// Sent back when paying.
  final String ref;
  final String shopName;
  final String? shopCategory;

  /// The ref of the shop's photo.
  final String? shopPhoto;

  /// Their udhaar book there, and what is owed (paid separately).
  final int? bookId;
  final int duePaise;

  /// Razorpay's payment screen, confirmed by itself ([testMode]: pretend money).
  final bool online;
  final bool testMode;

  /// The shop's own UPI ID, confirmed by the shop.
  final bool upi;

  static PayShop? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final ref = json['ref'];
    final name = json['shopName'];
    if (ref is! String || name is! String) return null;
    return PayShop(
      ref: ref,
      shopName: name,
      shopCategory: json['shopCategory'] as String?,
      shopPhoto: json['shopPhoto'] as String?,
      bookId: json['bookId'] as int?,
      duePaise: json['duePaise'] as int? ?? 0,
      online: json['online'] == true,
      testMode: json['testMode'] == true,
      upi: json['upi'] == true,
    );
  }
}

/// The shop's own QR.
class ShopQrCode {
  const ShopQrCode({required this.shopName, required this.data, this.worksInUpiApps = false});

  final String shopName;
  final String data;

  /// The shop has a UPI ID, so PhonePe / GPay can read it too.
  final bool worksInUpiApps;

  static ShopQrCode? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['shopName'];
    final data = json['data'];
    if (name is! String || data is! String) return null;
    return ShopQrCode(shopName: name, data: data, worksInUpiApps: json['worksInUpiApps'] == true);
  }
}

/// A UPI payment that was started; "did you pay?" is not answered yet.
class UnfinishedUpi {
  const UnfinishedUpi({required this.payment, required this.shopName});

  final Payment payment;
  final String shopName;

  static UnfinishedUpi? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final payment = Payment.fromJson(json['payment']);
    final name = json['shopName'];
    return payment == null || name is! String ? null : UnfinishedUpi(payment: payment, shopName: name);
  }
}

class PayShops {
  const PayShops({this.shops = const [], this.unfinished = const []});

  final List<PayShop> shops;
  final List<UnfinishedUpi> unfinished;

  static PayShops? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    return PayShops(
      shops: [for (final s in json['shops'] as List? ?? const []) ?PayShop.fromJson(s)],
      unfinished: [for (final u in json['unfinished'] as List? ?? const []) ?UnfinishedUpi.fromJson(u)],
    );
  }
}

/// A payment to a shop that was just started: online (key and order) or by UPI.
class ShopPayStart {
  const ShopPayStart({
    required this.payment,
    required this.shopName,
    required this.contact,
    this.keyId,
    this.orderId,
    this.upiId,
    this.upiName,
  });

  final Payment payment;
  final String shopName;
  final String contact;
  final String? keyId;
  final String? orderId;
  final String? upiId;
  final String? upiName;

  static ShopPayStart? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final payment = Payment.fromJson(json['payment']);
    final name = json['shopName'];
    if (payment == null || name is! String) return null;
    return ShopPayStart(
      payment: payment,
      shopName: name,
      contact: json['contact'] as String? ?? '',
      keyId: json['keyId'] as String?,
      orderId: json['orderId'] as String?,
      upiId: json['upiId'] as String?,
      upiName: json['upiName'] as String?,
    );
  }
}

/// A standard UPI payment link for the shop's own UPI ID, with the amount
/// filled in. Any UPI app (PhonePe, GPay, Paytm) reads it as a QR.
String upiLink({required String upiId, String? name, required int amountPaise, String? note}) {
  final params = <String, String>{
    'pa': upiId,
    if ((name ?? '').isNotEmpty) 'pn': name!,
    'am': (amountPaise / 100).toStringAsFixed(2),
    'cu': 'INR',
    if ((note ?? '').isNotEmpty) 'tn': note!,
  };
  final query = params.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');
  return 'upi://pay?$query';
}

/// "₹250 received" said out loud in the shop's language (with the payer's
/// name when known).
String receivedWords(int paise, AppLanguage language, {String? from}) {
  final amount = rupees(paise).replaceAll('₹', '').replaceAll(',', '');
  final name = (from ?? '').trim();
  final hasName = name.isNotEmpty && !name.contains('@');
  return switch (language) {
    AppLanguage.telugu => hasName ? '$name నుండి $amount రూపాయలు వచ్చాయి' : '$amount రూపాయలు వచ్చాయి',
    AppLanguage.hindi => hasName ? '$name से $amount रुपये मिले' : '$amount रुपये मिले',
    AppLanguage.kannada => hasName ? '$name ಅವರಿಂದ $amount ರೂಪಾಯಿ ಬಂದಿದೆ' : '$amount ರೂಪಾಯಿ ಬಂದಿದೆ',
    AppLanguage.tamil => hasName ? '$name இடமிருந்து $amount ரூபாய் வந்துள்ளது' : '$amount ரூபாய் வந்துள்ளது',
    AppLanguage.english => hasName ? '$amount rupees received from $name' : '$amount rupees received',
  };
}

/// "Ravi says they paid ₹250" said out loud: a UPI payment not checked yet, so it
/// must never sound like the money came.
String saysPaidWords(int paise, AppLanguage language, {required String from}) {
  final amount = rupees(paise).replaceAll('₹', '').replaceAll(',', '');
  final name = from.trim().isEmpty ? null : from.trim();
  return switch (language) {
    AppLanguage.telugu => '${name ?? 'ఒకరు'} $amount రూపాయలు కట్టినట్టు చెప్పారు. చెక్ చేయండి',
    AppLanguage.hindi => '${name == null ? 'किसी ने' : '$name ने'} कहा कि $amount रुपये भेजे हैं. जाँच लीजिए',
    AppLanguage.kannada => '${name ?? 'ಒಬ್ಬರು'} $amount ರೂಪಾಯಿ ಕಳುಹಿಸಿದ್ದೇವೆ ಎಂದು ಹೇಳಿದ್ದಾರೆ. ಪರಿಶೀಲಿಸಿ',
    AppLanguage.tamil => '${name ?? 'ஒருவர்'} $amount ரூபாய் அனுப்பியதாகச் சொல்கிறார். சரிபார்க்கவும்',
    AppLanguage.english => '${name ?? 'Someone'} says they paid $amount rupees. Please check',
  };
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
