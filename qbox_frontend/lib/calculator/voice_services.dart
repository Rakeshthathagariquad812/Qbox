import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../translator/languages.dart';
import '../translator/say_numbers.dart';

/// A problem with voice, with a message written for the shopkeeper.
class VoiceException implements Exception {
  const VoiceException(this.message);

  final String message;

  @override
  String toString() => 'VoiceException($message)';
}

/// How long to wait for someone to speak, and how long a pause ends it.
class VoicePace {
  const VoicePace({
    this.waitForSpeech = const Duration(seconds: 8),
    this.pause = const Duration(milliseconds: 1500),
    this.serverPause = const Duration(milliseconds: 1100),
    this.unfinished,
    this.unfinishedPause = const Duration(seconds: 4),
    this.longest = const Duration(seconds: 25),
  });

  /// For writing down longer speech (notes): time to think between sentences.
  const VoicePace.relaxed()
    : this(pause: const Duration(seconds: 3), serverPause: const Duration(milliseconds: 2000));

  /// Nothing said for this long: stop.
  final Duration waitForSpeech;

  /// Quiet for this long after the last word: done.
  final Duration pause;

  /// The same, when the QBOX server does the hearing.
  final Duration serverPause;

  /// True when more must follow ("20 plus"): then [unfinishedPause] is waited.
  final bool Function(String words)? unfinished;
  final Duration unfinishedPause;

  /// Never listens longer than this (the QBOX server's hearing).
  final Duration longest;

  Duration pauseAfter(String words) => unfinished?.call(words) ?? false ? unfinishedPause : pause;

  Duration get longestPause => unfinished != null && unfinishedPause > pause ? unfinishedPause : pause;
}

/// Listens to the microphone and turns speech into text.
abstract class VoiceInput {
  /// Listens until the person stops talking. [onWords] receives the words
  /// heard so far. Returns everything heard (may be empty).
  /// [localeId] picks the language heard, e.g. 'te_IN' for Telugu.
  /// [onReady] is called when the microphone is really open.
  Future<String> listen({
    required void Function(String words) onWords,
    String localeId = 'en_IN',
    VoicePace pace = const VoicePace(),
    void Function()? onReady,
  });

  /// Stops listening early; [listen] then returns what was heard.
  Future<void> stop();
}

/// What else the last words might have been, when the microphone can say.
abstract class VoiceGuesses {
  List<String> get guesses;
}

/// Something that gets ready before it is used, so it starts faster.
abstract class VoiceWarmUp {
  Future<void> warmUp({String localeId});
}

/// Says text out loud.
abstract class Speaker {
  /// Says [text] in the voice for [locale] (e.g. 'te-IN' for Telugu).
  Future<void> say(String text, {String locale = 'en-IN'});

  /// True if the phone has a voice for [locale].
  Future<bool> hasVoice(String locale);

  Future<void> stop();
}

/// A speaker that knows when it has finished talking.
abstract class SpeakerDone {
  Future<void> get finished;
}

/// A speaker with more than one voice (alerts can use a chosen one).
abstract class VoiceChoices {
  /// The phone's voices for [locale] ('te-IN'), by name; those that work offline first.
  Future<List<String>> voices(String locale);

  /// Says [text] in [voice] (a name from [voices]); the usual voice if it is gone.
  Future<void> sayWith(String text, {required String locale, required String voice});
}

/// Uses the phone's own speech recognition (Google on Android), in Indian English.
class DeviceVoiceInput implements VoiceInput, VoiceGuesses {
  DeviceVoiceInput({SpeechToText? speech}) : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  bool _ready = false;
  Completer<String>? _done;
  String _heard = '';
  VoicePace _pace = const VoicePace();
  void Function()? _onReady;

  /// The phone said that THIS listening has begun; anything before that belongs
  /// to the one before.
  bool _begun = false;
  Timer? _quiet;
  Timer? _giveUp;
  Timer? _readyTimer;

  @override
  List<String> guesses = const [];

  static const _busy = VoiceException('The microphone is busy. Try again in a moment.');

  @override
  Future<String> listen({
    required void Function(String words) onWords,
    String localeId = 'en_IN',
    VoicePace pace = const VoicePace(),
    void Function()? onReady,
  }) async {
    if (!_ready) {
      try {
        _ready = await _speech.initialize(onError: _onError, onStatus: _onStatus);
      } catch (_) {
        _ready = false;
      }
      if (!_ready) {
        throw const VoiceException(
          'Voice is not available. Allow microphone access for QBOX in phone settings.',
        );
      }
    }
    final last = _done;
    if (last != null && !last.isCompleted) last.complete(_heard);
    // After the last words the phone still counts itself as listening for a few
    // seconds, and quietly refuses to start again: end that first.
    await _free();

    _heard = '';
    guesses = const [];
    _pace = pace;
    _onReady = onReady;
    final done = _done = Completer<String>();
    var started = await _begin(done, onWords, localeId);
    if (!started && !done.isCompleted) {
      await _free(always: true);
      started = await _begin(done, onWords, localeId);
    }
    if (!started && !done.isCompleted) {
      _clear();
      throw _busy;
    }
    if (!done.isCompleted) _restart(pace.waitForSpeech);
    try {
      return await done.future;
    } finally {
      if (identical(done, _done)) {
        _clear();
        // Free the microphone for the next time.
        if (_speech.isListening) unawaited(_speech.cancel().catchError((_) {}));
      }
    }
  }

  Future<bool> _begin(Completer<String> done, void Function(String words) onWords, String localeId) async {
    _begun = false;
    try {
      await _speech.listen(
        onResult: (result) {
          if (done.isCompleted || !identical(done, _done)) return;
          _isReady();
          final words = result.recognizedWords;
          guesses = [for (final a in result.alternates) a.recognizedWords];
          if (words != _heard || result.finalResult) {
            _heard = words;
            onWords(words);
          }
          if (result.finalResult) {
            _finish();
          } else if (words.trim().isNotEmpty) {
            _restart(_pace.pauseAfter(words));
          }
        },
        // Loudness comes only once the microphone is open.
        onSoundLevelChange: (_) => _isReady(),
        listenOptions: SpeechListenOptions(
          localeId: localeId,
          listenFor: const Duration(seconds: 60),
          pauseFor: _pace.longestPause,
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (_) {
      return false;
    }
    if (!_begun && _speech.isListening) _begun = true;
    // QBOX decides when it is over: the plugin would count its pause from the
    // start, before anything was said.
    if (_begun) {
      try {
        _speech.changePauseFor(const Duration(seconds: 60));
      } catch (_) {}
    }
    return _begun;
  }

  Future<void> _free({bool always = false}) async {
    if (!always && !_speech.isListening) return;
    _begun = false;
    try {
      await _speech.cancel();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  /// Quiet for [after] from now ends the listening.
  void _restart(Duration after) {
    if (_giveUp?.isActive ?? false) return; // already ending
    _quiet?.cancel();
    _quiet = Timer(after, _endNow);
  }

  void _endNow() {
    _quiet?.cancel();
    unawaited(_speech.stop().catchError((_) {}));
    // The phone answers with its final words, usually at once. If it is slow,
    // what was heard so far is used.
    _giveUp?.cancel();
    _giveUp = Timer(Duration(milliseconds: _heard.trim().isEmpty ? 1200 : 600), _finish);
  }

  void _clear() {
    _quiet?.cancel();
    _giveUp?.cancel();
    _readyTimer?.cancel();
    _onReady = null;
  }

  void _isReady() {
    final tell = _onReady;
    if (!_begun || tell == null) return;
    _onReady = null;
    _readyTimer?.cancel();
    tell();
  }

  @override
  Future<void> stop() async {
    if (_done == null || _done!.isCompleted) return;
    _endNow();
  }

  void _onStatus(String status) {
    if (status == SpeechToText.listeningStatus) {
      _begun = true;
      _readyTimer?.cancel();
      // Some phones send no loudness.
      _readyTimer = Timer(const Duration(milliseconds: 700), _isReady);
    } else if (status == SpeechToText.doneStatus && _begun) {
      _finish();
    }
  }

  void _onError(SpeechRecognitionError error) {
    final done = _done;
    if (done == null || done.isCompleted) return;
    // Left over from the listening that was just ended.
    if (!_begun && error.errorMsg == 'error_client') return;
    final message = switch (error.errorMsg) {
      'error_no_match' ||
      'error_speech_timeout' => null, // heard nothing useful
      'error_network' || 'error_network_timeout' || 'error_server' =>
        'Voice needs internet on this phone. Check your connection and try again.',
      'error_permission' || 'error_insufficient_permissions' =>
        'Allow microphone access for QBOX in phone settings.',
      'error_busy' => _busy.message,
      'error_language_not_supported' || 'error_language_unavailable' =>
        'This language is not set up for voice on this phone. '
            'Add it in phone Settings > Languages > Voice typing.',
      _ => 'Could not hear you. Please try again.',
    };
    if (message == null) {
      done.complete(_heard);
    } else {
      done.completeError(VoiceException(message));
    }
  }

  void _finish() {
    final done = _done;
    if (done != null && !done.isCompleted) done.complete(_heard);
  }
}

/// Uses the phone's text-to-speech voices (Indian English by default).
class DeviceSpeaker implements Speaker, SpeakerDone, VoiceChoices {
  final FlutterTts _tts = FlutterTts();
  String? _locale;
  bool _handlers = false;
  Completer<void>? _talking;
  Future<void>? _best;

  /// Google's voices have all 5 languages; some phones (Samsung) come with
  /// another voice that has only a few.
  Future<void> _useBestVoices() => _best ??= () async {
    const google = 'com.google.android.tts';
    try {
      final engines = await _tts.getEngines;
      if (engines is! List || !engines.contains(google) || await _tts.getDefaultEngine == google) return;
      await _tts.setEngine(google).timeout(const Duration(seconds: 4));
    } catch (_) {
      // The phone's own, then.
    }
  }();

  @override
  Future<void> get finished =>
      _talking?.future.timeout(const Duration(seconds: 25), onTimeout: () {}) ?? Future<void>.value();

  void _quiet([Object? _]) {
    final t = _talking;
    _talking = null;
    if (t != null && !t.isCompleted) t.complete();
  }

  @override
  Future<void> say(String text, {String locale = 'en-IN'}) async {
    await _useBestVoices();
    try {
      if (!_handlers) {
        _tts.setCompletionHandler(_quiet);
        _tts.setErrorHandler(_quiet);
        _handlers = true;
      }
      if (_locale != locale) {
        var use = locale;
        if (locale == 'en-IN' && await _tts.isLanguageAvailable('en-IN') != true) use = 'en-US';
        await _tts.setLanguage(use);
        await _tts.setSpeechRate(0.45); // a little slower, so every number is clear
        _locale = locale;
      }
      await _tts.stop();
      _quiet();
      _talking = Completer<void>();
      final language = AppLanguage.values.firstWhere(
        (l) => l.voiceLocale == locale,
        orElse: () => AppLanguage.english,
      );
      await _tts.speak(sayable(text, language));
    } catch (_) {
      _quiet();
      // Speaking is a bonus: never let it break the screen.
    }
  }

  @override
  Future<List<String>> voices(String locale) async {
    await _useBestVoices();
    String norm(Object? l) => '$l'.toLowerCase().replaceAll('_', '-');
    try {
      final all = await _tts.getVoices;
      if (all is! List) return const [];
      final names = <String>[
        for (final v in all)
          if (v is Map && norm(v['locale']) == norm(locale) && v['name'] is String) v['name'] as String,
      ];
      // Offline voices first; then by name, so the list stays in the same order.
      names.sort((a, b) {
        final online = a.contains('network').toString().compareTo(b.contains('network').toString());
        return online != 0 ? online : a.compareTo(b);
      });
      return names.toSet().toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> sayWith(String text, {required String locale, required String voice}) async {
    await _useBestVoices();
    try {
      await _tts.setLanguage(locale);
      await _tts.setSpeechRate(0.45);
      await _tts.setVoice({'name': voice, 'locale': locale});
    } catch (_) {
      // The usual voice, then.
    }
    _locale = null; // the next say() sets its own language (and the usual voice) again
    if (!_handlers) {
      _tts.setCompletionHandler(_quiet);
      _tts.setErrorHandler(_quiet);
      _handlers = true;
    }
    try {
      await _tts.stop();
      _quiet();
      _talking = Completer<void>();
      final language = AppLanguage.values.firstWhere((l) => l.voiceLocale == locale, orElse: () => AppLanguage.english);
      await _tts.speak(sayable(text, language));
    } catch (_) {
      _quiet();
    }
  }

  @override
  Future<bool> hasVoice(String locale) async {
    await _useBestVoices();
    try {
      return await _tts.isLanguageAvailable(locale) == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _quiet();
  }
}
