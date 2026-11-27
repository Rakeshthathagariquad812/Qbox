// Voice mistakes found in the QA run of 2026-11-26, with the real sentences
// and the real translations the AI server gave.
import 'package:flutter_test/flutter_test.dart';
import 'package:qbox_app/calculator/voice_math.dart';
import 'package:qbox_app/calculator/voice_talk.dart';
import 'package:qbox_app/calendar/calendar_models.dart';
import 'package:qbox_app/calendar/spoken_time.dart';
import 'package:qbox_app/calendar/voice_event.dart';
import 'package:qbox_app/translator/languages.dart';
import 'package:qbox_app/udhaar/udhaar_models.dart';
import 'package:qbox_app/udhaar/voice_udhaar.dart';

void main() {
  group('udhaar: which way the money went', () {
    test('Telugu words decide, not the translation', () {
      const te = AppLanguage.telugu;
      expect(nativeKind('సురేష్ 100 కట్టాడు', te), EntryKind.payment); // translated "Suresh scored 100"
      expect(nativeKind('రవి 200 ఇచ్చాడు', te), EntryKind.payment);
      expect(nativeKind('రవి దగ్గర 250 తీసుకున్నాను', te), EntryKind.payment);
      expect(nativeKind('రవి ఉద్దెర కట్టాడు', te), EntryKind.payment);
      expect(nativeKind('రమేష్ కి 300 ఇచ్చాను', te), EntryKind.credit);
      expect(nativeKind('రవి 500 ఉద్దెర', te), EntryKind.credit);
      expect(nativeKind('రవి 500 తీసుకున్నాడు', te), EntryKind.credit);
      expect(nativeKind('రవి 500', te), isNull);
      expect(nativeKind('రవి 500 చెల్లించేసాడు', te), EntryKind.payment);
    });

    test('Hindi words decide, not the translation', () {
      const hi = AppLanguage.hindi;
      expect(nativeKind('सुरेश ने 100 जमा किए', hi), EntryKind.payment); // translated "Suresh collected 100"
      expect(nativeKind('रमेश ने 200 दिए', hi), EntryKind.payment);
      expect(nativeKind('रवि से 250 लिए', hi), EntryKind.payment);
      expect(nativeKind('रवि ने उधार चुकाया', hi), EntryKind.payment);
      expect(nativeKind('रवि को 500 उधार दिया', hi), EntryKind.credit);
      expect(nativeKind('मैंने रवि को 500 दिए', hi), EntryKind.credit);
      expect(nativeKind('रवि 300 उधार', hi), EntryKind.credit);
      expect(nativeKind('रवि ने 500 का सामान लिया', hi), EntryKind.credit);
      expect(nativeKind('रवि 500', hi), isNull);
      expect(nativeKind('रवि ने 500 अदा किए', hi), EntryKind.payment);
    });

    const customers = [
      UdhaarCustomer(id: 1, name: 'Ravi', mobile: '9876500001'),
      UdhaarCustomer(id: 2, name: 'Ramesh', mobile: '9876500002'),
      UdhaarCustomer(id: 3, name: 'Suresh', mobile: '9876500003'),
    ];

    test('English: "I took 250 from Ravi" is a payment, "Ravi took 500" is udhaar', () {
      expect(parseSpokenUdhaar('I took 250 from Ravi', customers)!.kind, EntryKind.payment);
      expect(parseSpokenUdhaar('Suresh collected 100', customers)!.kind, EntryKind.payment);
      final took = parseSpokenUdhaar('Ravi took 500', customers)!;
      expect(took.kind, EntryKind.credit);
      expect(took.amountPaise, 50000);
      expect(parseSpokenUdhaar('I took 250 from Ravi', customers)!.spokenName, '');
    });

    test('a name that only sounds like one in the book is not taken as sure', () {
      final r = parseSpokenUdhaar('Rajesh 300 udhaar', customers)!;
      expect(r.matches.single.name, 'Ramesh');
      expect(r.sure, isFalse);
      expect(r.spokenName, 'Rajesh');
      final exact = parseSpokenUdhaar('Ramesh 300 udhaar', customers)!;
      expect(exact.sure, isTrue);
      expect(namedExactly('rajesh 300', customers.sublist(1, 2)), isFalse);
      // Written from Hindi/Telugu letters: vowels and "h" differ, still Ramesh.
      expect(namedExactly('rames ko 200', customers.sublist(1, 2)), isTrue);
      expect(namedExactly('ramesha 200', customers.sublist(1, 2)), isTrue);
      expect(parseSpokenUdhaar('Sures paid 100', customers)!.sure, isTrue);
      expect(heardName('rajesh 300', customers.sublist(1, 2)), 'Rajesh');
    });
  });

  group('calculator', () {
    test('more Telugu and Hindi calculator words', () {
      expect(readSum('వంద గుణించి మూడు', AppLanguage.telugu), '100×3');
      expect(readSum('ఇరవై మరియు ముప్పై', AppLanguage.telugu), '20+30');
      expect(readSum('బీస్ ప్లస్ తీస్', AppLanguage.telugu), isNot('2030'));
      expect(readSum('बीस और तीस', AppLanguage.hindi), '20+30');
      expect(readSum('सौ गुणे तीन', AppLanguage.hindi), '100×3');
    });

    test('"from 500 take away 120", the Telugu, Hindi and English way', () {
      expect(readSum('500 లో 120 తీసివేయి', AppLanguage.telugu), '500−120');
      expect(readSum('ఐదు వందల లో నుంచి నూట ఇరవై తీసేయి', AppLanguage.telugu), '500−120');
      expect(readSum('500 में से 120 घटाओ', AppLanguage.hindi), '500−120');
      expect(parseSpokenMath('Subtract 120 from 500'), '500−120');
      expect(parseSpokenMath('Remove 120 from 500'), '500−120');
    });

    test('"and" joins a number only after hundred/thousand', () {
      expect(parseSpokenMath('twenty and thirty'), '20+30');
      expect(parseSpokenMath('250 and 300'), '250+300');
      expect(parseSpokenMath('one hundred and three'), '103');
      expect(parseSpokenMath('two thousand and fifty'), '2050');
      expect(parseSpokenMath('two hundred and fifty plus 10'), '250+10');
    });

    test('a translation that changes the numbers is not used', () {
      const te = AppLanguage.telugu;
      // Real translations from the AI server.
      expect(trustedTranslation('One hundred and three', 'వంద ఏదో మూడు', te), isNull);
      expect(trustedTranslation('Four thousand divided by four', 'వెయ్యి ఏదో నాలుగు', te), isNull);
      expect(trustedTranslation('Twenty and thirty', 'बीस ऐसे तीस', AppLanguage.hindi), '20+30');
      expect(trustedTranslation('Hundred times three', 'వంద ఏదో మూడు', te), '100×3');
      expect(trustedTranslation('just a hundred', 'ఏదో', te), isNull); // not a sum
    });
  });

  group('calendar', () {
    final now = DateTime(2026, 11, 26, 9, 0);
    String at(EventDraft d) => '${d.minuteOfDay! ~/ 60}:${(d.minuteOfDay! % 60).toString().padLeft(2, '0')}';

    test('"evening 7" is 7 PM', () {
      final d = parseSpokenEvent('tomorrow evening 7 call', now)!;
      expect(at(d), '19:00');
      expect(d.title, 'Call');
      expect(at(parseSpokenEvent('pay rent at 7 in the evening', now)!), '19:00');
      expect(at(parseSpokenEvent('morning 9 open shop', now)!), '9:00');
      expect(parseSpokenEvent('evening 5 kg rice', now)!.minuteOfDay, 18 * 60); // 5 kg is not a time
    });

    test('"each month" repeats monthly (translated from Telugu)', () {
      final d = parseSpokenEvent('Rent must be paid on the 5th of each month', now)!;
      expect(d.repeat, Repeat.monthly);
      expect(d.day, DateTime(2026, 12, 5));
      expect(d.title, 'Rent must be paid');
      expect(parseSpokenEvent('pay salary each month on the 1st', now)!.repeat, Repeat.monthly);
      expect(parseSpokenEvent('stock check each week', now)!.repeat, Repeat.weekly);
    });

    test('"3: 10 p.m" from a translation, and clean titles', () {
      final d = parseSpokenEvent('Call the supplier tomorrow at 3: 10 p.m', now,
          spokenTime: nativeTime('రేపు సాయంత్రం 3:10 కి సప్లయర్ కి ఫోన్ చేయాలి', AppLanguage.telugu))!;
      expect(at(d), '15:10');
      expect(d.title, 'Call the supplier');
      final noon = parseSpokenEvent('call Ravi at 12 noon', now)!;
      expect(at(noon), '12:00');
      expect(noon.title, 'Call Ravi');
    });
  });
}
