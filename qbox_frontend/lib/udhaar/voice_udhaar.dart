/// Turns a spoken udhaar sentence into who, how much, and which way.
///
///   "Ramesh 250 udhaar"          -> Ramesh, ₹250, udhaar given
///   "Ramesh paid 100"            -> Ramesh, ₹100, payment received
///   "received two fifty from Ravi" -> Ravi, ₹250, payment received
///   "gave Suresh 500"            -> Suresh, ₹500, udhaar given
///   "Suresh gave 500"            -> Suresh, ₹500, payment received
///
/// English sentences are read here; for Telugu and Hindi the way the money
/// went is read from the words themselves ([nativeKind]), and the rest from
/// the English translation. The result is always shown to the shopkeeper to
/// check before anything is saved.
library;

import '../calculator/voice_math.dart';
import '../translator/languages.dart';
import 'udhaar_models.dart';

class SpokenUdhaar {
  const SpokenUdhaar({
    required this.kind,
    required this.matches,
    required this.spokenName,
    this.amountPaise,
    this.sure = true,
  });

  final EntryKind kind;
  final int? amountPaise;

  /// Customers whose name was heard. One = clear; several = ask which one;
  /// none = maybe a new customer called [spokenName].
  final List<UdhaarCustomer> matches;

  /// The words left over that look like a name ("Suresh"), for a new customer.
  /// When the name only sounded like one in the book ([sure] false), the name
  /// as heard ("Rajesh" heard, "Ramesh" in the book).
  final String spokenName;

  /// False when [matches] only sound like the name heard (one letter differs):
  /// the shopkeeper is asked, since "Rajesh" may be a new customer, not Ramesh.
  final bool sure;
}

/// Which way the money went, read straight from Telugu or Hindi words. The
/// translation often gets this wrong ("సురేష్ 100 కట్టాడు", Suresh paid 100,
/// came back as "Suresh scored 100"). Null when the words do not say.
EntryKind? nativeKind(String spoken, AppLanguage language) {
  final words = spoken
      .replaceAll(RegExp(r'[.,!?।"₹]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  bool has(Set<String> set) => words.any(set.contains);
  switch (language) {
    case AppLanguage.telugu:
      // He paid / he gave / I took (from him) / it came: a payment.
      if (has(_tePaid) || has(_teHeGave) || has(_teITook) || has(_teCame)) return EntryKind.payment;
      // I gave (him) / he took / udhaar: udhaar given.
      if (has(_teIGave) || has(_teHeTook) || has(_teCredit)) return EntryKind.credit;
      return null;
    case AppLanguage.hindi:
      if (has(_hiPaid)) return EntryKind.payment;
      // "रमेश ने 200 दिए" = he paid; "रवि को 500 दिए" = given to him.
      final gave = has(_hiGave);
      if (gave && words.contains('ने')) return EntryKind.payment;
      if (gave && words.contains('को')) return EntryKind.credit;
      // "रवि से 250 लिए" = I took from him (paid); "रवि ने लिया" = he took.
      final took = has(_hiTook);
      if (took && words.contains('से')) return EntryKind.payment;
      if (took || has(_hiCredit)) return EntryKind.credit;
      return null;
    case AppLanguage.english:
    case AppLanguage.kannada:
    case AppLanguage.tamil:
      return null;
  }
}

const _tePaid = {
  'కట్టాడు', 'కట్టింది', 'కట్టారు', 'కట్టేశాడు', 'కట్టేసాడు', 'కట్టేసింది', 'కట్టేశారు', 'చెల్లించాడు',
  'చెల్లించింది', 'చెల్లించారు', 'చెల్లించేశాడు', 'జమ', 'పంపాడు', 'పంపించాడు', 'పంపింది', 'పేమెంట్', 'క్లియర్',
    'చెల్లించేసాడు', 'చెల్లించేసింది', 'చెల్లించేశారు', 'కట్టేసారు',
};
const _teHeGave = {'ఇచ్చాడు', 'ఇచ్చింది', 'ఇచ్చారు', 'ఇచ్చేశాడు', 'ఇచ్చేసాడు', 'ఇచ్చేసింది', 'ఇచ్చేశారు'};
const _teITook = {'తీసుకున్నాను', 'తీసుకున్నా', 'తీసుకున్నాం', 'అందింది', 'అందాయి'};
const _teCame = {'వచ్చింది', 'వచ్చాయి'};
const _teIGave = {'ఇచ్చాను', 'ఇచ్చా', 'ఇచ్చాం', 'ఇచ్చాము'};
const _teHeTook = {
  'తీసుకున్నాడు', 'తీసుకుంది', 'తీసుకున్నారు', 'తీసుకెళ్ళాడు', 'తీసుకెళ్లాడు', 'తీసుకెళ్ళింది', 'తీసుకెళ్లింది',
  'తీసుకెళ్ళారు', 'పట్టుకెళ్ళాడు', 'కొన్నాడు', 'కొనుక్కున్నాడు',
};
const _teCredit = {
  'ఉద్దెర', 'ఉద్ధెర', 'ఉద్దర', 'ఉద్ధర', 'ఉద్దెరు', 'ఉధార్', 'ఉధారు', 'ఉద్దారు', 'అప్పు', 'బాకీ', 'ఖాతా', 'ఖాతాలో',
  'క్రెడిట్',
};
const _hiPaid = {
  'जमा', 'चुकाया', 'चुकाए', 'चुकाये', 'चुकाई', 'चुका', 'चुकता', 'लौटाया', 'लौटाए', 'लौटाये', 'लौटाई', 'वापस',
  'भुगतान', 'पेमेंट', 'मिले', 'मिला', 'मिली', 'भेजे', 'भेजा', 'भेजी', 'भरे', 'भरा','अदा',
};
const _hiGave = {'दिया', 'दिए', 'दिये', 'दी', 'दे'};
const _hiTook = {'लिया', 'लिए', 'लिये', 'ली', 'ले'};
const _hiCredit = {'उधार', 'उधारी', 'बाकी', 'बाक़ी', 'खाता', 'खाते', 'कर्ज', 'कर्ज़', 'क़र्ज़', 'क्रेडिट'};

const _paymentWords = {
  'paid', 'pay', 'pays', 'payment', 'received', 'receive', 'got', 'returned',
  'return', 'deposit', 'deposited', 'deposits', 'collected', 'jama', 'cleared', 'settled', 'repaid',
  // Telugu (in English letters): he paid / he gave / it came
  'kattadu', 'kattindi', 'kattaru', 'katti', 'chellinchadu', 'ichadu', 'icchadu',
  'ichindi', 'ichaaru', 'vachindi', 'vacchindi',
  // Hindi (in English letters): returned / paid off
  'wapas', 'vapas', 'lautaya', 'lautaye', 'chukaya', 'chukaye', 'chuka', 'bharpai',
};
const _creditWords = {
  'udhaar', 'udhar', 'udaar', 'udhari', 'udhaari', 'credit', 'took', 'take',
  'taken', 'borrowed', 'loan', 'baki', 'baaki', 'owes', 'due', 'given', 'khata',
  // Telugu: he took / I gave
  'teesukunnadu', 'tisukunnadu', 'teeskunnadu', 'tiskunnadu', 'teesukundi',
  'ichanu', 'icchanu', 'appu',
  // Hindi: took
  'liya', 'liye',
};
// Hindi "diya/diye" (gave) depends on who: "Teja ne 500 diye" = he paid,
// "Teja ko 500 diye" = udhaar given to him.
const _hindiGave = {'diya', 'diye', 'di', 'de', 'dia'};
const _fillerWords = {
  'rupees', 'rupee', 'rs', 'to', 'from', 'for', 'the', 'a', 'an', 'me', 'us',
  'of', 'and', 'on', 'has', 'have', 'is', 'was', 'today', 'add', 'write',
  'entry', 'he', 'she', 'ki', 'ko', 'ka', 'se', 'ne', 'hai', 'please', 'mr',
  'mrs', 'sir', 'garu', 'anna', 'akka', 'bhai', 'ji', 'amount', 'cash', 'by',
  'in', 'with', 'customer', 'gave', 'give', 'i', 'my', 'we',
};

SpokenUdhaar? parseSpokenUdhaar(String spoken, List<UdhaarCustomer> customers) {
  final words = spoken
      .toLowerCase()
      .replaceAll(RegExp(r'(?<=[0-9]),(?=[0-9])'), '') // 1,500 -> 1500
      .replaceAll(RegExp(r'[₹]'), ' ')
      .replaceAll(RegExp(r"[^a-z0-9.\s]"), ' ')
      .split(RegExp(r'\s+'))
      .map((w) => w.endsWith('.') ? w.substring(0, w.length - 1) : w)
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return null;

  // 1. Who: customers whose name words were heard.
  final nameWordIndexes = <int>{};
  var best = 0;
  var matches = <UdhaarCustomer>[];
  for (final c in customers) {
    final hit = nameHits(c.name, words);
    if (hit.isEmpty) continue;
    if (hit.length > best) {
      best = hit.length;
      matches = [c];
    } else if (hit.length == best) {
      matches.add(c);
    }
  }
  for (final c in matches) {
    nameWordIndexes.addAll(nameHits(c.name, words));
  }
  final firstNameAt = nameWordIndexes.isEmpty
      ? -1
      : nameWordIndexes.reduce((a, b) => a < b ? a : b);

  // 2. Which way.
  var kind = EntryKind.credit;
  final gaveAt = words.indexOf('gave');
  if (words.any(_paymentWords.contains)) {
    kind = EntryKind.payment;
  } else if (words.any(_hindiGave.contains) && (words.contains('ne') || words.contains('ko'))) {
    kind = words.contains('ne') ? EntryKind.payment : EntryKind.credit;
  } else if (gaveAt >= 0) {
    // "Suresh gave 500" / "gave me 500" = he paid; "gave Suresh 500" = udhaar.
    final next = gaveAt + 1 < words.length ? words[gaveAt + 1] : '';
    final customerBefore = firstNameAt >= 0 && firstNameAt < gaveAt;
    if (next == 'me' || next == 'us' || customerBefore) kind = EntryKind.payment;
  } else if (words.any(const {'took', 'taken', 'take'}.contains) && (words.contains('from') || words.contains('i'))) {
    // "I took 250 from Ravi" = he paid; "Ravi took 500" = udhaar.
    kind = EntryKind.payment;
  }

  // 3. How much: the rest of the words, read like the calculator does.
  final rest = [
    for (var i = 0; i < words.length; i++)
      if (!nameWordIndexes.contains(i) &&
          !_paymentWords.contains(words[i]) &&
          !_creditWords.contains(words[i]) &&
          !_hindiGave.contains(words[i]))
        words[i],
  ];
  // Words the calculator would read as + or ÷ ("add 250", "paid by cash").
  const notMaths = {'add', 'by', 'over', 'less', 'x'};
  final sum = parseSpokenMath(rest.where((w) => !notMaths.contains(w)).join(' '));
  final value = sum == null ? null : double.tryParse(sum);
  final amount = value == null || value <= 0 ? null : (value * 100).round();

  // 4. Leftover name words, for a customer not in the book yet.
  final spokenName = rest
      .where((w) => !_fillerWords.contains(w) && !_isNumberish(w))
      .take(3)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  if (amount == null && matches.isEmpty) return null;
  final sure = matches.every((c) => nameHits(c.name, words, exact: true).isNotEmpty);
  return SpokenUdhaar(
    kind: kind,
    amountPaise: amount,
    matches: matches,
    spokenName: matches.isEmpty ? spokenName : (sure ? '' : _asHeard(nameWordIndexes.map((i) => words[i]))),
    sure: sure,
  );
}

String _asHeard(Iterable<String> words) => words.map((w) => '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

List<String> _latinWords(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .toList();

/// True when each of [matches] is named exactly in [text] (not just sounds alike).
bool namedExactly(String text, List<UdhaarCustomer> matches) {
  final words = _latinWords(text);
  return matches.every((c) => nameHits(c.name, words, exact: true).isNotEmpty);
}

/// The words of [text] that sounded like the name of one of [matches] ("Rajesh").
String heardName(String text, List<UdhaarCustomer> matches) {
  final words = _latinWords(text);
  final at = <int>{for (final c in matches) ...nameHits(c.name, words)}.toList()..sort();
  return _asHeard(at.map((i) => words[i]));
}

/// Customers whose name appears in [text] (best matches only). Used for names
/// heard in Telugu/Hindi/Kannada/Tamil script, after writing them in English letters.
List<UdhaarCustomer> customersIn(String text, List<UdhaarCustomer> customers) {
  final words = _latinWords(text);
  var best = 0;
  var matches = <UdhaarCustomer>[];
  for (final c in customers) {
    final hits = nameHits(c.name, words).length;
    if (hits == 0) continue;
    if (hits > best) {
      best = hits;
      matches = [c];
    } else if (hits == best) {
      matches.add(c);
    }
  }
  return matches;
}

/// The amount when [text] holds exactly one number written in digits
/// ("తేజ 500 ఇచ్చాడు" -> 50000 paise). Null otherwise.
int? digitsAmount(String text) {
  final numbers = RegExp(r'[0-9][0-9,]*(?:\.[0-9]{1,2})?')
      .allMatches(text)
      .map((m) => double.tryParse(m[0]!.replaceAll(',', '')))
      .whereType<double>()
      .toList();
  if (numbers.length != 1 || numbers.single <= 0) return null;
  return (numbers.single * 100).round();
}

/// Positions of [words] that match a word of [name] (allowing one wrong
/// letter in longer names, since speech recognition often misspells them;
/// [exact]: only words that are surely the name: spelt the same, or differing
/// only in vowels or "h" ("rames", "ramesha" = Ramesh; "rajesh" is not).
Set<int> nameHits(String name, List<String> words, {bool exact = false}) {
  final parts = name
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((p) => p.length >= 2)
      .toList();
  final hits = <int>{};
  for (final part in parts) {
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      final hit = exact
          ? w == part || (_skeleton(part).length >= 2 && _skeleton(w) == _skeleton(part))
          : w == part || (part.length >= 4 && w.length >= 4 && _closeEnough(w, part));
      if (hit) {
        hits.add(i);
        break;
      }
    }
  }
  return hits;
}

/// The consonants of a name, each once: "ramesh", "rames", "ramesha" -> "rms".
String _skeleton(String word) => word.replaceAll(RegExp('[aeiouhy]'), '').replaceAllMapped(RegExp(r'(.)\1+'), (m) => m[1]!);

/// True when [a] and [b] differ by at most one letter (added, removed or changed).
bool _closeEnough(String a, String b) {
  if ((a.length - b.length).abs() > 1) return false;
  var i = 0;
  var j = 0;
  var edits = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      i++;
      j++;
      continue;
    }
    if (++edits > 1) return false;
    if (a.length > b.length) {
      i++;
    } else if (b.length > a.length) {
      j++;
    } else {
      i++;
      j++;
    }
  }
  return edits + (a.length - i) + (b.length - j) <= 1;
}

const _numberWords = {
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty', 'thirty', 'forty',
  'fifty', 'sixty', 'seventy', 'eighty', 'ninety', 'hundred', 'thousand',
  'lakh', 'lakhs', 'lac', 'crore', 'point', 'oh', 'o',
};

bool _isNumberish(String w) => _numberWords.contains(w) || double.tryParse(w) != null;
