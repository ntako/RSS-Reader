import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../services/rss_service.dart';
import '../services/tts_service.dart';
import '../services/gemma_service.dart';

// ── Gemma model lifecycle ──────────────────────────────────────────────────────

enum GemmaModelState { checking, notDownloaded, downloading, ready, error }

class GemmaModelNotifier extends StateNotifier<(GemmaModelState, double)> {
  final GemmaService _service;

  /// Motivo dell'ultimo caricamento fallito (stato [GemmaModelState.error]).
  String? lastError;

  GemmaModelNotifier(this._service) : super((GemmaModelState.checking, 0)) {
    init();
  }

  /// All'avvio carica il modello già installato. Se il file c'è ma non si
  /// carica (formato sbagliato, memoria, finestra di contesto…) lo stato
  /// diventa [GemmaModelState.error] invece di restare "Verifica…" per sempre.
  @visibleForTesting
  Future<void> init() async {
    try {
      final downloaded = await GemmaService.isModelDownloaded();
      if (downloaded) {
        await _service.loadModel();
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

  Future<void> download(String url) async {
    state = (GemmaModelState.downloading, 0);
    try {
      await _service.downloadModel(url, onProgress: (progress) {
        state = (GemmaModelState.downloading, progress);
      });
    } catch (e) {
      state = (GemmaModelState.notDownloaded, 0);
      throw Exception('Errore download: $e');
    }
    try {
      await _service.loadModel();
      state = (GemmaModelState.ready, 1);
    } catch (e) {
      state = (GemmaModelState.notDownloaded, 0);
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
      state = (GemmaModelState.notDownloaded, 0);
      throw Exception('Errore copia file: $e');
    }
    try {
      await _service.loadModel();
      state = (GemmaModelState.ready, 1);
    } catch (e) {
      state = (GemmaModelState.notDownloaded, 0);
      throw Exception(
        'Modello copiato ma non caricabile.\n'
        'Assicurati di aver scaricato il formato LiteRT (non PyTorch/GGUF).\n\nDettaglio: $e',
      );
    }
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
