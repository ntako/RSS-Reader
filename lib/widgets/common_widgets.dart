import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../database/database.dart';
import '../providers/app_providers.dart';
import '../services/tts_service.dart';

// ── Article card ──────────────────────────────────────────────────────────────

class ArticleCard extends StatelessWidget {
  final Article article;
  final String feedTitle;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;

  const ArticleCard({
    super.key,
    required this.article,
    required this.feedTitle,
    required this.onTap,
    required this.onFavoriteToggle,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final isRead = article.isRead;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isRead ? AppTheme.divider : AppTheme.accent.withOpacity(0.3),
            width: isRead ? 1 : 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Immagine
            if (article.imageUrl != null)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                child: CachedNetworkImage(
                  imageUrl: article.imageUrl!,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => _shimmerBox(160),
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Feed name + date
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(feedTitle,
                            style: tt.labelMedium?.copyWith(color: AppTheme.accent)),
                      ),
                      const Spacer(),
                      if (article.publishedAt != null)
                        Text(
                          _formatDate(article.publishedAt!),
                          style: tt.labelMedium,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Titolo
                  Text(
                    article.title,
                    style: tt.titleLarge?.copyWith(
                      color: isRead ? AppTheme.textSecondary : AppTheme.textPrimary,
                      fontWeight: isRead ? FontWeight.w400 : FontWeight.w600,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (article.description != null && article.description!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      article.description!,
                      style: tt.bodyMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 10),
                  // Footer
                  Row(
                    children: [
                      if (article.author != null)
                        Expanded(
                          child: Text(
                            article.author!,
                            style: tt.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const Spacer(),
                      if (article.aiSummary != null)
                        _chip(context, '✦ AI', AppTheme.accent),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: onFavoriteToggle,
                        child: Icon(
                          article.isFavorite ? Icons.bookmark : Icons.bookmark_border,
                          size: 18,
                          color: article.isFavorite ? AppTheme.accent : AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inHours < 1) return '${diff.inMinutes}m fa';
    if (diff.inHours < 24) return '${diff.inHours}h fa';
    if (diff.inDays < 7) return '${diff.inDays}g fa';
    return DateFormat('d MMM', 'it').format(dt);
  }
}

// ── Feed tile ─────────────────────────────────────────────────────────────────

class FeedTile extends StatelessWidget {
  final FeedSource feed;
  final int unreadCount;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const FeedTile({
    super.key,
    required this.feed,
    required this.unreadCount,
    required this.isSelected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.accent.withOpacity(0.12) : AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppTheme.accent : AppTheme.divider,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            _feedIcon(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(feed.title,
                      style: tt.titleMedium?.copyWith(
                        color: isSelected ? AppTheme.accent : AppTheme.textPrimary,
                      )),
                  if (feed.lastFetched != null)
                    Text(
                      'Aggiornato ${_formatDate(feed.lastFetched!)}',
                      style: tt.labelMedium,
                    ),
                ],
              ),
            ),
            if (unreadCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.accent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$unreadCount',
                  style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700,
                    color: AppTheme.background,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18, color: AppTheme.textMuted),
              color: AppTheme.surfaceHigh,
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'delete') onDelete();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'edit',
                  child: Row(children: [
                    const Icon(Icons.edit_outlined, size: 16, color: AppTheme.textSecondary),
                    const SizedBox(width: 8),
                    Text('Modifica', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(children: [
                    const Icon(Icons.delete_outline, size: 16, color: AppTheme.error),
                    const SizedBox(width: 8),
                    Text('Elimina', style: TextStyle(color: AppTheme.error, fontSize: 13)),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _feedIcon() {
    if (feed.iconUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: CachedNetworkImage(
          imageUrl: feed.iconUrl!,
          width: 32, height: 32, fit: BoxFit.cover,
          errorWidget: (_, __, ___) => _defaultIcon(),
        ),
      );
    }
    return _defaultIcon();
  }

  Widget _defaultIcon() {
    return Container(
      width: 32, height: 32,
      decoration: BoxDecoration(
        color: AppTheme.accent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Icon(Icons.rss_feed, size: 18, color: AppTheme.accent),
    );
  }

  String _formatDate(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inHours < 1) return '${diff.inMinutes}m fa';
    if (diff.inHours < 24) return '${diff.inHours}h fa';
    return DateFormat('d MMM HH:mm', 'it').format(dt);
  }
}

// ── Shimmer loading box ───────────────────────────────────────────────────────

Widget _shimmerBox(double height) {
  return Shimmer.fromColors(
    baseColor: AppTheme.surfaceHigh,
    highlightColor: AppTheme.divider,
    child: Container(height: height, color: AppTheme.surfaceHigh),
  );
}

// ── TTS Player bar ────────────────────────────────────────────────────────────

class TtsPlayerBar extends ConsumerWidget {
  final bool isPlaying;
  final bool isPaused;
  final String articleTitle;
  final VoidCallback onPlayPause;
  final VoidCallback onStop;
  final double speed;
  final ValueChanged<double> onSpeedChanged;

  const TtsPlayerBar({
    super.key,
    required this.isPlaying,
    required this.isPaused,
    required this.articleTitle,
    required this.onPlayPause,
    required this.onStop,
    required this.speed,
    required this.onSpeedChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final queue = ref.watch(ttsQueueProvider);

    final displayTitle = queue.hasQueue ? (queue.currentTitle ?? articleTitle) : articleTitle;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceHigh,
        border: const Border(top: BorderSide(color: AppTheme.divider)),
      ),
      child: Row(
        children: [
          const Icon(Icons.volume_up_rounded, size: 16, color: AppTheme.accent),
          const SizedBox(width: 8),
          // Titolo + contatore coda
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayTitle,
                  style: tt.bodySmall?.copyWith(color: AppTheme.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
                if (queue.hasQueue)
                  Text(
                    '${queue.index + 1} / ${queue.total}',
                    style: tt.labelMedium?.copyWith(color: AppTheme.textMuted),
                  ),
              ],
            ),
          ),
          // Velocità
          GestureDetector(
            onTap: () {
              const speeds = [0.3, 0.5, 0.7, 1.0];
              final idx = speeds.indexOf(speed);
              onSpeedChanged(speeds[(idx + 1) % speeds.length]);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${speed}x',
                style: tt.labelMedium?.copyWith(color: AppTheme.accentSoft),
              ),
            ),
          ),
          // Skip prev (solo in modalità coda)
          if (queue.hasQueue)
            IconButton(
              icon: const Icon(Icons.skip_previous_rounded, size: 20, color: AppTheme.textMuted),
              onPressed: () => ref.read(ttsQueueProvider.notifier).skipPrev(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          // Play/Pause
          IconButton(
            icon: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: AppTheme.accent,
            ),
            onPressed: onPlayPause,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          // Skip next (solo in modalità coda)
          if (queue.hasQueue)
            IconButton(
              icon: const Icon(Icons.skip_next_rounded, size: 20, color: AppTheme.textMuted),
              onPressed: () => ref.read(ttsQueueProvider.notifier).skipNext(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          // Stop
          IconButton(
            icon: const Icon(Icons.stop_rounded, size: 20, color: AppTheme.textMuted),
            onPressed: onStop,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ],
      ),
    );
  }
}
