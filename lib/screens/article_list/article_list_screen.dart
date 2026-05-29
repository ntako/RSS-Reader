import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/app_theme.dart';
import '../../database/database.dart';
import '../../providers/app_providers.dart';
import '../../services/tts_service.dart';
import '../../widgets/common_widgets.dart';
import '../article_reader/article_reader_screen.dart';

class ArticleListScreen extends ConsumerWidget {
  final int? feedId;
  final String title;

  const ArticleListScreen({super.key, this.feedId, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final articlesAsync = ref.watch(articlesStreamProvider(feedId));
    final feedsAsync = ref.watch(feedsStreamProvider);
    final isRefreshing = ref.watch(isRefreshingProvider);
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          // Pulsante play playlist
          articlesAsync.whenOrNull(
            data: (articles) => feedsAsync.whenOrNull(
              data: (feeds) {
                if (articles.isEmpty) return null;
                return IconButton(
                  icon: const Icon(Icons.playlist_play_rounded),
                  tooltip: 'Leggi tutti',
                  onPressed: () => _startPlaylist(context, ref, articles, feeds),
                );
              },
            ),
          ) ?? const SizedBox.shrink(),
          if (isRefreshing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _refresh(ref),
            ),
        ],
      ),
      body: articlesAsync.when(
        data: (articles) {
          if (articles.isEmpty) {
            return _emptyState(context, tt, ref);
          }
          return feedsAsync.when(
            data: (feeds) {
              final feedMap = {for (final f in feeds) f.id: f.title};
              return RefreshIndicator(
                onRefresh: () => _refresh(ref),
                color: AppTheme.accent,
                backgroundColor: AppTheme.surface,
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: articles.length,
                  itemBuilder: (_, i) {
                    final article = articles[i];
                    return ArticleCard(
                      article: article,
                      feedTitle: feedMap[article.feedId] ?? 'Feed',
                      onTap: () => _openArticle(context, ref, article),
                      onFavoriteToggle: () => _toggleFavorite(ref, article),
                    );
                  },
                ),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
          );
        },
        loading: () => _loadingShimmer(),
        error: (e, _) => Center(
          child: Text('Errore: $e', style: const TextStyle(color: AppTheme.error)),
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context, TextTheme tt, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.article_outlined, size: 56, color: AppTheme.textMuted),
          const SizedBox(height: 16),
          Text('Nessun articolo', style: tt.headlineMedium),
          const SizedBox(height: 8),
          Text('Aggiorna per caricare le notizie.', style: tt.bodyMedium),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () => _refresh(ref),
            icon: const Icon(Icons.refresh),
            label: const Text('Aggiorna ora'),
          ),
        ],
      ),
    );
  }

  Widget _loadingShimmer() {
    return ListView.builder(
      itemCount: 6,
      padding: const EdgeInsets.all(16),
      itemBuilder: (_, __) => Container(
        height: 130,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  Future<void> _refresh(WidgetRef ref) async {
    ref.read(isRefreshingProvider.notifier).state = true;
    try {
      await ref.read(rssServiceProvider).fetchAllFeeds();
    } finally {
      ref.read(isRefreshingProvider.notifier).state = false;
    }
  }

  void _openArticle(BuildContext context, WidgetRef ref, Article article) {
    ref.read(databaseProvider).markAsRead(article.id);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ArticleReaderScreen(articleId: article.id)),
    );
  }

  void _toggleFavorite(WidgetRef ref, Article article) {
    ref.read(databaseProvider).toggleFavorite(article.id, !article.isFavorite);
  }

  void _startPlaylist(BuildContext context, WidgetRef ref,
      List<Article> articles, List<FeedSource> feeds) {
    final feedMap = {for (final f in feeds) f.id: f};
    final items = buildTtsPlaylist(articles, feedMap);
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun articolo con contenuto leggibile')),
      );
      return;
    }
    ref.read(ttsStateProvider.notifier).state = TtsState.stopped;
    ref.read(ttsQueueProvider.notifier).startPlaylist(items).then((_) {
      ref.read(ttsStateProvider.notifier).state = TtsState.playing;
    });
  }
}
