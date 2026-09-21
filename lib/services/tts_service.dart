import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'tts_background.dart';

enum TtsState { stopped, playing, paused }

// Mappa codice RSS/ISO-639 → locale BCP-47 usato da flutter_tts
String langToTtsLocale(String? feedLang) {
  if (feedLang == null) return 'it-IT';
  final lang = feedLang.toLowerCase().trim();
  if (lang.contains('-')) return lang;
  const map = {
    'it': 'it-IT', 'en': 'en-US', 'fr': 'fr-FR',
    'de': 'de-DE', 'es': 'es-ES', 'pt': 'pt-PT',
    'nl': 'nl-NL', 'pl': 'pl-PL', 'ru': 'ru-RU',
    'ja': 'ja-JP', 'zh': 'zh-CN', 'ar': 'ar-SA',
  };
  return map[lang] ?? 'it-IT';
}

class TtsItem {
  final int articleId;
  final String title;
  final String text;
  final String language; // BCP-47

  const TtsItem({
    required this.articleId,
    required this.title,
    required this.text,
    required this.language,
  });
}

class TtsService {
  final FlutterTts _tts = FlutterTts();
  TtsState _state = TtsState.stopped;
  int _currentWordStart = 0;
  int _currentWordEnd = 0;

  // ── Coda ──────────────────────────────────────────────────────────────────
  List<TtsItem> _queue = [];
  int _queueIndex = 0;

  // ── Parti del testo in lettura ────────────────────────────────────────────
  // Il motore TTS di Android rifiuta i testi oltre ~4000 caratteri
  // ("Text too long"): un articolo lungo si legge a parti, in sequenza.
  static const maxUtteranceChars = 3500;
  List<String> _chunks = [];
  int _chunkIndex = 0;
  int _chunkOffset = 0; // caratteri delle parti già lette

  TtsState get state => _state;
  bool get isPlaying => _state == TtsState.playing;
  bool get isPaused => _state == TtsState.paused;
  bool get hasQueue => _queue.isNotEmpty;
  int get queueIndex => _queueIndex;
  int get queueLength => _queue.length;
  TtsItem? get currentItem =>
      _queue.isNotEmpty && _queueIndex < _queue.length ? _queue[_queueIndex] : null;

  // Callbacks
  void Function(TtsState state)? onStateChange;
  void Function(int start, int end)? onWordBoundary;
  void Function(String error)? onError;
  void Function(int index, int total, TtsItem item)? onQueueAdvance;
  void Function()? onQueueComplete;

  Future<void> init({String language = 'it-IT'}) async {
    await _tts.setLanguage(language);
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      _state = TtsState.playing;
      onStateChange?.call(_state);
    });

    _tts.setCompletionHandler(() async {
      // Non è finito l'articolo, solo una parte: passa alla successiva senza
      // segnalare alcuno stop all'interfaccia.
      if (_chunkIndex < _chunks.length - 1) {
        _chunkOffset += _chunks[_chunkIndex].length;
        _chunkIndex++;
        await _tts.speak(_chunks[_chunkIndex]);
        return;
      }
      _chunks = [];
      _state = TtsState.stopped;
      onStateChange?.call(_state);
      if (_queue.isNotEmpty) {
        if (_queueIndex < _queue.length - 1) {
          _queueIndex++;
          await _playCurrentQueueItem();
        } else {
          final cb = onQueueComplete;
          _queue = [];
          _queueIndex = 0;
          await _stopForeground();
          cb?.call();
        }
      }
    });

    _tts.setPauseHandler(() {
      _state = TtsState.paused;
      onStateChange?.call(_state);
    });

    _tts.setContinueHandler(() {
      _state = TtsState.playing;
      onStateChange?.call(_state);
    });

    _tts.setErrorHandler((msg) {
      _chunks = [];
      _state = TtsState.stopped;
      onStateChange?.call(_state);
      onError?.call(msg);
    });

    _tts.setProgressHandler((text, start, end, word) {
      // start/end sono relativi alla parte in lettura: riportati all'intero testo.
      _currentWordStart = start + _chunkOffset;
      _currentWordEnd = end + _chunkOffset;
      onWordBoundary?.call(_currentWordStart, _currentWordEnd);
    });
  }

  // ── Singolo articolo ──────────────────────────────────────────────────────

  Future<void> speak(String text, {String language = 'it-IT', String? title}) async {
    _queue = [];
    _queueIndex = 0;
    if (_state == TtsState.playing) await _tts.stop();
    await _tts.setLanguage(language);
    await _startForeground(title ?? 'Lettura in corso');
    await _speakChunked(text);
  }

  Future<void> _speakChunked(String text) async {
    _chunks = splitForSpeech(text);
    _chunkIndex = 0;
    _chunkOffset = 0;
    await _tts.speak(_chunks.first);
  }

  /// Divide [text] in parti di al massimo [maxChars] caratteri, tagliando
  /// preferibilmente a fine paragrafo, poi a fine frase, poi su uno spazio.
  /// Non perde né aggiunge caratteri: le parti, concatenate, ridanno [text].
  @visibleForTesting
  static List<String> splitForSpeech(String text, {int maxChars = maxUtteranceChars}) {
    final chunks = <String>[];
    var start = 0;
    while (text.length - start > maxChars) {
      final window = text.substring(start, start + maxChars);
      final minCut = maxChars ~/ 3; // niente parti minuscole
      var cut = -1;
      final paragraph = window.lastIndexOf('\n\n');
      if (paragraph >= minCut) cut = paragraph + 2;
      if (cut < 0) {
        final sentence = RegExp(r'[.!?…»”"]\s').allMatches(window).lastOrNull;
        if (sentence != null && sentence.end >= minCut) cut = sentence.end;
      }
      if (cut < 0) {
        final space = RegExp(r'\s').allMatches(window).lastOrNull;
        if (space != null && space.end > 0) cut = space.end;
      }
      if (cut < 0) cut = maxChars; // nessun punto di taglio: taglio netto
      chunks.add(text.substring(start, start + cut));
      start += cut;
    }
    chunks.add(text.substring(start));
    return chunks;
  }

  Future<void> pause() async {
    if (_state == TtsState.playing) await _tts.pause();
  }

  Future<void> stop() async {
    _queue = [];
    _queueIndex = 0;
    _chunks = [];
    await _tts.stop();
    _state = TtsState.stopped;
    onStateChange?.call(_state);
    await _stopForeground();
  }

  // ── Coda articoli ─────────────────────────────────────────────────────────

  Future<void> startQueue(List<TtsItem> items) async {
    if (items.isEmpty) return;
    await _tts.stop();
    _queue = items;
    _queueIndex = 0;
    await _playCurrentQueueItem();
  }

  Future<void> skipNext() async {
    if (_queue.isEmpty || _queueIndex >= _queue.length - 1) return;
    await _tts.stop();
    _queueIndex++;
    await _playCurrentQueueItem();
  }

  Future<void> skipPrev() async {
    if (_queue.isEmpty || _queueIndex <= 0) return;
    await _tts.stop();
    _queueIndex--;
    await _playCurrentQueueItem();
  }

  Future<void> _playCurrentQueueItem() async {
    final item = _queue[_queueIndex];
    onQueueAdvance?.call(_queueIndex, _queue.length, item);
    await _startForeground(item.title);
    await _tts.setLanguage(item.language);
    await _speakChunked('${item.title}. ${item.text}');
  }

  // ── Foreground service ────────────────────────────────────────────────────

  Future<void> _startForeground(String title) async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(notificationText: title);
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'Lettore RSS',
        notificationText: title,
        callback: startCallback,
      );
    }
  }

  Future<void> _stopForeground() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  // ── Utility ───────────────────────────────────────────────────────────────

  Future<void> setSpeechRate(double rate) => _tts.setSpeechRate(rate.clamp(0.1, 1.0));
  Future<void> setPitch(double pitch) => _tts.setPitch(pitch.clamp(0.5, 2.0));
  Future<void> setLanguage(String lang) => _tts.setLanguage(lang);
  Future<List<dynamic>> getLanguages() async => (await _tts.getLanguages) as List<dynamic>;

  int get wordStart => _currentWordStart;
  int get wordEnd => _currentWordEnd;

  void dispose() {
    _tts.stop();
    _queue = [];
  }
}
