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
      _state = TtsState.stopped;
      onStateChange?.call(_state);
      onError?.call(msg);
    });

    _tts.setProgressHandler((text, start, end, word) {
      _currentWordStart = start;
      _currentWordEnd = end;
      onWordBoundary?.call(start, end);
    });
  }

  // ── Singolo articolo ──────────────────────────────────────────────────────

  Future<void> speak(String text, {String language = 'it-IT', String? title}) async {
    _queue = [];
    _queueIndex = 0;
    if (_state == TtsState.playing) await _tts.stop();
    await _tts.setLanguage(language);
    await _startForeground(title ?? 'Lettura in corso');
    await _tts.speak(text);
  }

  Future<void> pause() async {
    if (_state == TtsState.playing) await _tts.pause();
  }

  Future<void> stop() async {
    _queue = [];
    _queueIndex = 0;
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
    await _tts.speak('${item.title}. ${item.text}');
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
