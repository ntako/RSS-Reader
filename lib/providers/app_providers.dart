import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../services/app_settings.dart';
import '../services/rss_service.dart';
import '../services/tts_service.dart';
import '../services/gemma_service.dart';

// ── Gemma model lifecycle ──────────────────────────────────────────────────────

enum GemmaModelState { checking, notDownloaded, downloading, ready, error }

class GemmaModelNotifier extends StateNotifier<(GemmaModelState, double)> {
  final GemmaService _service;

  /// Motivo dell'ultimo caricamento fallito (stato [GemmaModelState.error]).
  String? lastError;

  /// 'cpu' o 'gpu': quello scelto in Impostazioni, applicato a ogni caricamento.
  String backend = 'cpu';

  /// Vero per una volta sola, subito dopo l'avvio, se l'ultimo tentativo con
  /// la GPU non è arrivato a completarsi (quasi certamente un crash nativo)
  /// e per questo la GPU è stata disattivata automaticamente. La UI lo mostra
  /// e poi chiama [acknowledgeGpuDowngrade] per non ripeterlo.
  bool gpuDowngradedByCrash = false;

  GemmaModelNotifier(this._service) : super((GemmaModelState.checking, 0)) {
    init();
  }

  GemmaBackend get _backendEnum => backend == 'gpu' ? GemmaBackend.gpu : GemmaBackend.cpu;

  /// All'avvio carica il modello già installato. Se il file c'è ma non si
  /// carica (formato sbagliato, memoria, finestra di contesto…) lo stato
  /// diventa [GemmaModelState.error] invece di restare "Verifica…" per sempre.
  ///
  /// Prima di tutto legge il segno lasciato da [GemmaService.loadModel]
  /// (vedi lì): se l'avvio precedente ha tentato la GPU e non è arrivato a
  /// cancellarlo, quasi certamente è morto nel tentativo. In tal caso la GPU
  /// viene disattivata per questo e i prossimi avvii, finché l'utente non la
  /// riattiva a mano da Impostazioni.
  @visibleForTesting
  Future<void> init() async {
    backend = await AppSettings.gemmaBackend();
    final danglingAttempt = await AppSettings.consumeGemmaLoadAttempt();
    if (danglingAttempt == 'gpu') {
      backend = 'cpu';
      await AppSettings.saveGemmaBackend('cpu');
      gpuDowngradedByCrash = true;
    }

    try {
      final downloaded = await GemmaService.isModelDownloaded();
      if (downloaded) {
        await _service.loadModel(backend: _backendEnum);
        lastError = null;
        state = (GemmaModelState.ready, 1);
      } else {
        state = (GemmaModelState.notDownloaded, 0);
      }
    } catch (e) {
      lastError = '$e';
      state = (GemmaModelState.error, 0);
    }
  }

  /// Da chiamare dopo aver mostrato l'avviso di downgrade, per non ripeterlo
  /// finché l'app resta aperta. `gpuDowngradedByCrash` non fa parte di
  /// `state`, quindi chi lo legge deve far ridisegnare da sé la propria UI
  /// (uno `setState` locale) dopo averlo chiamato.
  void acknowledgeGpuDowngrade() => gpuDowngradedByCrash = false;

  /// Cambia il backend e, se un modello è già installato, lo ricarica subito
  /// su quello nuovo. Se non c'è ancora nessun modello, la scelta si applica
  /// al primo caricamento.
  Future<void> setBackend(String value) async {
    if (value != 'cpu' && value != 'gpu') return;
    backend = value;
    await AppSettings.saveGemmaBackend(value);
    if (await GemmaService.isModelDownloaded()) await _reload();
  }

  Future<void> _reload() async {
    state = (GemmaModelState.checking, 0);
    try {
      await _service.loadModel(backend: _backendEnum);
      lastError = null;
      state = (GemmaModelState.ready, 1);
    } catch (e) {
      lastError = '$e';
      state = (GemmaModelState.error, 0);
    }
  }

  /// Lo stato reale del servizio, da usare quando un'operazione fallisce:
  /// un tentativo di sostituzione può fallire prima ancora di toccare il
  /// modello già caricato, che allora resta pronto ("ready"), non
  /// "notDownloaded" — altrimenti l'interfaccia direbbe che Gemma non è
  /// configurato mentre in realtà sta ancora funzionando.
  Future<(GemmaModelState, double)> _currentState() async {
    if (_service.isReady) return (GemmaModelState.ready, 1.0);
    if (await GemmaService.isModelDownloaded()) return (GemmaModelState.error, 0.0);
    return (GemmaModelState.notDownloaded, 0.0);
  }

  Future<void> download(String url) async {
    state = (GemmaModelState.downloading, 0);
    try {
      await _service.downloadModel(url, onProgress: (progress) {
        state = (GemmaModelState.downloading, progress);
      });
    } catch (e) {
      state = await _currentState();
      throw Exception('Errore download: $e');
    }
    try {
      await _service.loadModel(backend: _backendEnum);
      lastError = null;
      state = (GemmaModelState.ready, 1);
    } catch (e) {
      lastError = '$e';
      state = (GemmaModelState.error, 0);
      throw Exception(
        'Download completato ma modello non caricabile.\n'
        'Assicurati di aver scaricato il formato LiteRT (non PyTorch/GGUF).\n\nDettaglio: $e',
      );
    }
  }

  Future<void> loadFromLocalFile(String sourcePath) async {
    state = (GemmaModelState.downloading, 0);
    try {
      await _service.copyFromLocalFile(sourcePath, onProgress: (progress) {
        state = (GemmaModelState.downloading, progress);
      });
    } catch (e) {
      // La copia può fallire prima di toccare il file buono già installato
      // (es. l'archivio scelto non contiene un modello): se era pronto,
      // resta pronto.
      state = await _currentState();
      throw Exception('Errore copia file: $e');
    }
    try {
      await _service.loadModel(backend: _backendEnum);
      lastError = null;
      state = (GemmaModelState.ready, 1);
    } catch (e) {
      lastError = '$e';
      state = (GemmaModelState.error, 0);
      throw Exception(
        'Modello copiato ma non caricabile.\n'
        'Assicurati di aver scaricato il formato LiteRT (non PyTorch/GGUF).\n\nDettaglio: $e',
      );
    }
  }

  /// Rimuove il modello installato e libera le risorse native.
  Future<void> removeModel() async {
    await _service.dispose();
    await GemmaService.deleteInstalledModel();
    lastError = null;
    state = (GemmaModelState.notDownloaded, 0);
  }
}

final gemmaModelProvider =
    StateNotifierProvider<GemmaModelNotifier, (GemmaModelState, double)>(
        (ref) => GemmaModelNotifier(ref.read(gemmaServiceProvider)));

// ── Core services ─────────────────────────────────────────────────────────────

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final rssServiceProvider = Provider<RssService>((ref) {
  return RssService(ref.read(databaseProvider));
});

final ttsServiceProvider = Provider<TtsService>((ref) {
  final svc = TtsService();
  svc.init();
  ref.onDispose(svc.dispose);
  return svc;
});

final gemmaServiceProvider = Provider<GemmaService>((ref) {
  final svc = GemmaService();
  ref.onDispose(svc.dispose);
  return svc;
});

// ── Feed streams ──────────────────────────────────────────────────────────────

final feedsStreamProvider = StreamProvider<List<FeedSource>>((ref) {
  return ref.watch(databaseProvider).watchAllFeeds();
});

final articlesStreamProvider =
    StreamProvider.family<List<Article>, int?>((ref, feedId) {
  final db = ref.watch(databaseProvider);
  if (feedId == null) return db.watchAllArticles();
  return db.watchArticlesByFeed(feedId);
});

final favoritesStreamProvider = StreamProvider<List<Article>>((ref) {
  return ref.watch(databaseProvider).watchFavorites();
});

// ── Refresh state ─────────────────────────────────────────────────────────────

final isRefreshingProvider = StateProvider<bool>((ref) => false);

// ── TTS state (singolo articolo) ──────────────────────────────────────────────

final ttsStateProvider = StateProvider<TtsState>((ref) => TtsState.stopped);
final ttsArticleIdProvider = StateProvider<int?>((ref) => null);

// ── TTS coda ──────────────────────────────────────────────────────────────────

class TtsQueueInfo {
  final int index;
  final int total;
  final String? currentTitle;

  const TtsQueueInfo({this.index = 0, this.total = 0, this.currentTitle});

  bool get hasQueue => total > 0;
}

class TtsQueueNotifier extends StateNotifier<TtsQueueInfo> {
  final TtsService _tts;

  TtsQueueNotifier(this._tts) : super(const TtsQueueInfo()) {
    _tts.onQueueAdvance = (index, total, item) {
      state = TtsQueueInfo(index: index, total: total, currentTitle: item.title);
    };
    _tts.onQueueComplete = () {
      state = const TtsQueueInfo();
    };
  }

  Future<void> startPlaylist(List<TtsItem> items) => _tts.startQueue(items);
  Future<void> skipNext() => _tts.skipNext();
  Future<void> skipPrev() => _tts.skipPrev();

  @override
  void dispose() {
    _tts.onQueueAdvance = null;
    _tts.onQueueComplete = null;
    super.dispose();
  }
}

final ttsQueueProvider =
    StateNotifierProvider<TtsQueueNotifier, TtsQueueInfo>(
        (ref) => TtsQueueNotifier(ref.read(ttsServiceProvider)));

// Costruisce la playlist da una lista di articoli e feed
List<TtsItem> buildTtsPlaylist(
    List<Article> articles, Map<int, FeedSource> feedMap) {
  return articles
      .map((a) {
        final lang = langToTtsLocale(feedMap[a.feedId]?.language);
        final text = RssService.articleText(a.content, a.description);
        if (text.isEmpty && a.title.isEmpty) return null;
        return TtsItem(
          articleId: a.id,
          title: a.title,
          text: text,
          language: lang,
        );
      })
      .whereType<TtsItem>()
      .toList();
}

// ── Home tab navigation ───────────────────────────────────────────────────────

/// Impostare a 3 per saltare alla scheda Impostazioni da qualsiasi screen.
final homeTabProvider = StateProvider<int>((ref) => 0);

// ── Selected feed ─────────────────────────────────────────────────────────────

final selectedFeedIdProvider = StateProvider<int?>((ref) => null);

// ── Unread counts ─────────────────────────────────────────────────────────────

final unreadCountProvider = FutureProvider.family<int, int>((ref, feedId) async {
  return ref.watch(databaseProvider).getUnreadCount(feedId);
});
