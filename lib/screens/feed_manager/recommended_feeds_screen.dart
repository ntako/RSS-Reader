import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/recommended_feeds.dart';
import '../../database/database.dart';
import '../../providers/app_providers.dart';
import '../../theme/app_theme.dart';

class RecommendedFeedsScreen extends ConsumerWidget {
  const RecommendedFeedsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final existing = ref.watch(feedsStreamProvider).valueOrNull
            ?.map((f) => f.url)
            .toSet() ??
        <String>{};

    final byCategory = <String, List<RecommendedFeed>>{};
    for (final f in recommendedFeeds) {
      byCategory.putIfAbsent(f.category, () => []).add(f);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Fonti consigliate')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '"Testo completo" indica che il feed contiene l\'articolo intero. '
              'Per gli altri l\'app scarica la pagina quando apri l\'articolo.',
              style: tt.bodySmall,
            ),
          ),
          for (final entry in byCategory.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
              child: Text(entry.key, style: tt.labelLarge),
            ),
            for (final feed in entry.value)
              _RecommendedTile(
                feed: feed,
                added: existing.contains(feed.url),
                onAdd: () => _add(context, ref, feed),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref, RecommendedFeed feed) async {
    final db = ref.read(databaseProvider);
    await db.insertFeedsSkippingExisting([
      FeedSourcesCompanion.insert(
        title: feed.title,
        url: feed.url,
        category: Value(feed.category),
        language: Value(feed.language),
        description: Value(feed.description),
      ),
    ]);
    final added = (await db.getAllFeeds()).where((f) => f.url == feed.url).firstOrNull;
    if (added == null) return;
    try {
      await ref.read(rssServiceProvider).fetchFeed(added);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${feed.title} aggiunta, ma il primo aggiornamento è fallito: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}

class _RecommendedTile extends StatefulWidget {
  final RecommendedFeed feed;
  final bool added;
  final Future<void> Function() onAdd;

  const _RecommendedTile({required this.feed, required this.added, required this.onAdd});

  @override
  State<_RecommendedTile> createState() => _RecommendedTileState();
}

class _RecommendedTileState extends State<_RecommendedTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final feed = widget.feed;
    final full = feed.textKind == FeedTextKind.fullText;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        title: Text(feed.title, style: tt.titleMedium),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(feed.description, style: tt.bodySmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _Badge(
                  full ? 'Testo completo' : 'Estratto',
                  full ? AppTheme.success : AppTheme.textSecondary,
                ),
                if (feed.paywall) const _Badge('Paywall', AppTheme.error),
                _Badge(feed.language.toUpperCase(), AppTheme.textSecondary),
              ],
            ),
          ],
        ),
        trailing: widget.added
            ? const Icon(Icons.check_circle, color: AppTheme.success)
            : _busy
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.add_circle_outline, color: AppTheme.accent),
                    tooltip: 'Aggiungi',
                    onPressed: () async {
                      setState(() => _busy = true);
                      try {
                        await widget.onAdd();
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
                  ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge(this.label, this.color);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
      );
}
