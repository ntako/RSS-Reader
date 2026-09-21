import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;
import '../../theme/app_theme.dart';
import '../../database/database.dart';
import '../../providers/app_providers.dart';
import '../../services/rss_service.dart';
import '../../services/gemma_service.dart';
import '../../services/opml_service.dart';
import 'background_settings_card.dart';
import 'recommended_feeds_screen.dart';
import '../../services/app_settings.dart';
import '../../services/notification_service.dart';

class FeedManagerScreen extends ConsumerStatefulWidget {
  const FeedManagerScreen({super.key});

  @override
  ConsumerState<FeedManagerScreen> createState() => _FeedManagerScreenState();
}

class _FeedManagerScreenState extends ConsumerState<FeedManagerScreen> {
  @override
  Widget build(BuildContext context) {
    final feedsAsync = ref.watch(feedsStreamProvider);
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Impostazioni'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Aggiungi feed',
            onPressed: () => _showAddFeedDialog(context),
          ),
          PopupMenuButton<String>(
            color: AppTheme.surfaceHigh,
            onSelected: (v) {
              switch (v) {
                case 'recommended':
                  Navigator.push(context, MaterialPageRoute(
                    builder: (_) => const RecommendedFeedsScreen(),
                  ));
                case 'import':
                  _importOpml();
                case 'export':
                  _exportOpml();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'recommended', child: Text('Fonti consigliate', style: TextStyle(color: AppTheme.textPrimary))),
              PopupMenuItem(value: 'import', child: Text('Importa OPML', style: TextStyle(color: AppTheme.textPrimary))),
              PopupMenuItem(value: 'export', child: Text('Esporta OPML', style: TextStyle(color: AppTheme.textPrimary))),
            ],
          ),
        ],
      ),
      // Tutta la pagina scorre: con le card in alto una Column + Expanded
      // andava in overflow quando la lista delle fonti era vuota.
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          // ── Gemma AI ───────────────────────────────────────────────────────
          const _GemmaSettingsCard(),
          const Divider(height: 1),
          // ── Aggiornamento in background ────────────────────────────────────
          const BackgroundSettingsCard(),
          const Divider(height: 1),
          // ── Fonti RSS ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Fonti RSS', style: tt.labelLarge),
          ),
          ...feedsAsync.when(
            data: (feeds) => feeds.isEmpty
                ? [_emptyState(context, tt)]
                : [
                    for (final feed in feeds)
                      _FeedListTile(
                        feed: feed,
                        onEdit: () => _showEditFeedDialog(context, feed),
                        onDelete: () => _confirmDelete(context, feed),
                        onRefresh: () => _refreshFeed(feed),
                        onToggleNotify: () => _toggleNotify(feed),
                      ),
                  ],
            loading: () => [
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
            error: (e, _) => [Center(child: Text('Errore: $e'))],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddFeedDialog(context),
        backgroundColor: AppTheme.accent,
        foregroundColor: AppTheme.background,
        icon: const Icon(Icons.add),
        label: const Text('Aggiungi fonte'),
      ),
    );
  }

  Widget _emptyState(BuildContext context, TextTheme tt) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rss_feed, size: 64, color: AppTheme.accent.withOpacity(0.4)),
            const SizedBox(height: 20),
            Text('Nessuna fonte', style: tt.headlineMedium),
            const SizedBox(height: 8),
            Text(
              'Aggiungi un feed RSS per iniziare a leggere le notizie.',
              style: tt.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _showAddFeedDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('Aggiungi feed'),
            ),
            TextButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const RecommendedFeedsScreen(),
              )),
              child: const Text('Oppure scegli tra le fonti consigliate'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddFeedDialog(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FeedFormSheet(
        onSave: (title, url, category, language) async {
          final db = ref.read(databaseProvider);
          await db.insertFeed(FeedSourcesCompanion.insert(
            title: title,
            url: url,
            category: Value(category),
            language: Value(language),
          ));
          if (context.mounted) Navigator.pop(context);
          _refreshFeedByUrl(url);
        },
      ),
    );
  }

  Future<void> _showEditFeedDialog(BuildContext context, FeedSource feed) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FeedFormSheet(
        initialTitle: feed.title,
        initialUrl: feed.url,
        initialCategory: feed.category,
        initialLanguage: feed.language,
        onSave: (title, url, category, language) async {
          final db = ref.read(databaseProvider);
          await db.updateFeed(feed.copyWith(
            title: title, url: url, category: category,
            language: Value(language),
          ));
          if (context.mounted) Navigator.pop(context);
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, FeedSource feed) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.surfaceHigh,
        title: Text('Elimina "${feed.title}"?',
            style: Theme.of(context).textTheme.titleLarge),
        content: Text(
          'Verranno eliminati anche tutti gli articoli associati.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(databaseProvider).deleteFeed(feed.id);
    }
  }

  Future<void> _refreshFeed(FeedSource feed) async {
    try {
      final svc = ref.read(rssServiceProvider);
      await svc.fetchFeed(feed);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${feed.title} aggiornato'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _toggleNotify(FeedSource feed) async {
    final enable = !feed.notify;
    if (enable) {
      if (!await NotificationService.requestPermission()) {
        _snack('Permesso notifiche negato: abilitalo dalle impostazioni di Android.', error: true);
        return;
      }
      if (!await AppSettings.backgroundRefreshEnabled()) {
        _snack('Attiva "Aggiorna in background" per ricevere gli avvisi.');
      }
    }
    await ref.read(databaseProvider).updateFeed(feed.copyWith(notify: enable));
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppTheme.error : AppTheme.success,
    ));
  }

  Future<void> _importOpml() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;

    try {
      final parsed = OpmlService.parse(utf8.decode(bytes, allowMalformed: true));
      final valid = parsed.where((f) => f.url.length <= 500 && Uri.tryParse(f.url)?.hasScheme == true);
      final added = await ref.read(databaseProvider).insertFeedsSkippingExisting([
        for (final f in valid)
          FeedSourcesCompanion.insert(
            title: f.title.length > 200 ? f.title.substring(0, 200) : f.title,
            url: f.url,
            category: Value(f.category),
            language: Value(f.language),
          ),
      ]);
      _snack(
        added == 0
            ? 'Nessuna nuova fonte: erano già tutte presenti.'
            : '$added fonti importate (${valid.length - added} già presenti)',
      );
      if (added > 0) ref.read(rssServiceProvider).fetchAllFeeds();
    } on FormatException catch (e) {
      _snack(e.message, error: true);
    }
  }

  Future<void> _exportOpml() async {
    final feeds = await ref.read(databaseProvider).getAllFeeds();
    if (feeds.isEmpty) {
      _snack('Nessuna fonte da esportare.', error: true);
      return;
    }
    final xml = OpmlService.export(feeds);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Esporta fonti',
      fileName: 'lettore-rss.opml',
      bytes: Uint8List.fromList(utf8.encode(xml)),
    );
    if (path != null) _snack('${feeds.length} fonti esportate');
  }

  Future<void> _refreshFeedByUrl(String url) async {
    final feeds = await ref.read(databaseProvider).getAllFeeds();
    final feed = feeds.where((f) => f.url == url).firstOrNull;
    if (feed != null) await _refreshFeed(feed);
  }
}

// ── Gemma settings card ───────────────────────────────────────────────────────

class _GemmaSettingsCard extends ConsumerStatefulWidget {
  const _GemmaSettingsCard();

  @override
  ConsumerState<_GemmaSettingsCard> createState() => _GemmaSettingsCardState();
}

class _GemmaSettingsCardState extends ConsumerState<_GemmaSettingsCard> {
  final _urlCtrl = TextEditingController();
  bool _copyingLocal = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickLocalFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['bin', 'task', 'tflite', 'litertlm', 'zip', 'gz', 'tgz'],
      dialogTitle: 'Seleziona modello Gemma (.task, .bin, .zip…)',
    );

    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    setState(() => _copyingLocal = true);
    ref.read(gemmaModelProvider.notifier).loadFromLocalFile(path).catchError((e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Errore copia file: $e'),
          backgroundColor: AppTheme.error,
        ));
      }
    }).whenComplete(() {
      if (mounted) setState(() => _copyingLocal = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final (modelState, progress) = ref.watch(gemmaModelProvider);
    final tt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 16, color: AppTheme.accent),
              const SizedBox(width: 8),
              Text('Gemma AI', style: tt.labelLarge),
              const Spacer(),
              _statusChip(modelState),
            ],
          ),
          const SizedBox(height: 12),
          if (modelState == GemmaModelState.ready) ...[
            Text(
              'Modello caricato e pronto.',
              style: tt.bodySmall?.copyWith(color: AppTheme.success),
            ),
          ] else if (modelState == GemmaModelState.downloading) ...[
            Row(
              children: [
                Expanded(
                  child: Text(_copyingLocal ? 'Estrazione/copia in corso…' : 'Download in corso…',
                      style: tt.bodySmall?.copyWith(color: AppTheme.accentSoft)),
                ),
                Text('${(progress * 100).toStringAsFixed(0)}%',
                    style: tt.labelMedium?.copyWith(color: AppTheme.accent)),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress > 0 ? progress : null,
                backgroundColor: AppTheme.divider,
                valueColor: const AlwaysStoppedAnimation(AppTheme.accent),
                minHeight: 4,
              ),
            ),
          ] else ...[
            if (modelState == GemmaModelState.error) ...[
              Text(
                'Il modello installato non si carica:\n'
                '${ref.read(gemmaModelProvider.notifier).lastError ?? 'errore sconosciuto'}\n'
                'Scegli un altro file (formato LiteRT).',
                style: tt.bodySmall?.copyWith(color: AppTheme.error),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              'Scarica da Kaggle → tab LiteRT → gemma-2-2b-it-cpu-int4 (~1.3 GB). '
              'Formati supportati: .task, .bin, .tflite (anche in .zip o .tar.gz).',
              style: tt.bodySmall,
            ),
            const SizedBox(height: 12),

            // ── Opzione 1: file locale ────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _pickLocalFile,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.accent,
                  side: const BorderSide(color: AppTheme.accent),
                ),
                icon: const Icon(Icons.folder_open_outlined, size: 16),
                label: const Text('Scegli file locale (.task / .bin / .zip…)'),
              ),
            ),

            const SizedBox(height: 10),
            Row(children: [
              const Expanded(child: Divider(color: AppTheme.divider)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('oppure', style: tt.bodySmall),
              ),
              const Expanded(child: Divider(color: AppTheme.divider)),
            ]),
            const SizedBox(height: 10),

            // ── Opzione 2: URL download ───────────────────────────────────
            TextField(
              controller: _urlCtrl,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'https://…',
                labelText: 'URL download modello',
                prefixIcon: Icon(Icons.link, size: 16, color: AppTheme.textMuted),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  final url = _urlCtrl.text.trim();
                  if (url.isEmpty) return;
                  ref.read(gemmaModelProvider.notifier).download(url).catchError((e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Download fallito: $e'),
                        backgroundColor: AppTheme.error,
                      ));
                    }
                  });
                },
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Scarica da URL'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusChip(GemmaModelState state) {
    final (label, color) = switch (state) {
      GemmaModelState.ready      => ('Pronto', AppTheme.success),
      GemmaModelState.downloading => ('Download…', AppTheme.accent),
      GemmaModelState.checking   => ('Verifica…', AppTheme.textMuted),
      GemmaModelState.notDownloaded => ('Non configurato', AppTheme.textMuted),
      GemmaModelState.error      => ('Errore', AppTheme.error),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

// ── Feed list tile ────────────────────────────────────────────────────────────

class _FeedListTile extends StatelessWidget {
  final FeedSource feed;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onRefresh;
  final VoidCallback onToggleNotify;

  const _FeedListTile({
    required this.feed,
    required this.onEdit,
    required this.onDelete,
    required this.onRefresh,
    required this.onToggleNotify,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: AppTheme.accent.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.rss_feed, color: AppTheme.accent, size: 20),
        ),
        title: Text(feed.title, style: tt.titleMedium),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(feed.url, style: tt.bodySmall, overflow: TextOverflow.ellipsis),
            Row(
              children: [
                if (feed.category.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4, right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.accent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(feed.category,
                        style: tt.labelMedium?.copyWith(color: AppTheme.accent)),
                  ),
                if (feed.language != null)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.textMuted.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      feed.language!.toUpperCase(),
                      style: tt.labelMedium?.copyWith(color: AppTheme.textSecondary),
                    ),
                  ),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                feed.notify ? Icons.notifications_active : Icons.notifications_none,
                size: 20,
                color: feed.notify ? AppTheme.accent : AppTheme.textMuted,
              ),
              onPressed: onToggleNotify,
              tooltip: feed.notify ? 'Disattiva notifiche' : 'Notifica nuovi articoli',
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20, color: AppTheme.textMuted),
              onPressed: onRefresh,
              tooltip: 'Aggiorna',
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20, color: AppTheme.textMuted),
              color: AppTheme.surfaceHigh,
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'delete') onDelete();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit',
                    child: Row(children: [
                      Icon(Icons.edit_outlined, size: 16, color: AppTheme.textSecondary),
                      SizedBox(width: 8),
                      Text('Modifica', style: TextStyle(color: AppTheme.textPrimary)),
                    ])),
                const PopupMenuItem(value: 'delete',
                    child: Row(children: [
                      Icon(Icons.delete_outline, size: 16, color: AppTheme.error),
                      SizedBox(width: 8),
                      Text('Elimina', style: TextStyle(color: AppTheme.error)),
                    ])),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Feed form bottom sheet ────────────────────────────────────────────────────

// Lingue supportate per TTS: codice BCP-47 → etichetta
const _kLanguages = <String?, String>{
  null:    'Automatico (dal feed)',
  'it-IT': 'Italiano',
  'en-US': 'English (US)',
  'en-GB': 'English (UK)',
  'fr-FR': 'Français',
  'de-DE': 'Deutsch',
  'es-ES': 'Español',
  'pt-PT': 'Português',
  'nl-NL': 'Nederlands',
  'pl-PL': 'Polski',
  'ru-RU': 'Русский',
  'ja-JP': '日本語',
  'zh-CN': '中文 (简体)',
  'ar-SA': 'العربية',
};

class _FeedFormSheet extends StatefulWidget {
  final String? initialTitle;
  final String? initialUrl;
  final String? initialCategory;
  final String? initialLanguage;
  final Future<void> Function(String title, String url, String category, String? language) onSave;

  const _FeedFormSheet({
    this.initialTitle,
    this.initialUrl,
    this.initialCategory,
    this.initialLanguage,
    required this.onSave,
  });

  @override
  State<_FeedFormSheet> createState() => _FeedFormSheetState();
}

class _FeedFormSheetState extends State<_FeedFormSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _categoryCtrl;
  String? _selectedLanguage;
  bool _loading = false;
  String? _error;

  final _categories = ['Generale', 'Tecnologia', 'Politica', 'Scienza', 'Sport', 'Cultura', 'Economia'];

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _urlCtrl = TextEditingController(text: widget.initialUrl);
    _categoryCtrl = TextEditingController(text: widget.initialCategory ?? 'Generale');
    _selectedLanguage = widget.initialLanguage;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _urlCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppTheme.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            widget.initialUrl == null ? 'Aggiungi feed RSS' : 'Modifica feed',
            style: tt.headlineMedium,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'URL del feed RSS',
              hintText: 'https://esempio.com/feed.xml',
              prefixIcon: Icon(Icons.link, size: 18, color: AppTheme.textMuted),
            ),
            keyboardType: TextInputType.url,
            style: TextStyle(color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
              labelText: 'Nome (opzionale)',
              hintText: 'Il mio feed preferito',
              prefixIcon: Icon(Icons.label_outline, size: 18, color: AppTheme.textMuted),
            ),
            style: TextStyle(color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 12),
          // Categoria dropdown
          DropdownButtonFormField<String>(
            value: _categoryCtrl.text,
            dropdownColor: AppTheme.surfaceHigh,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Categoria',
              prefixIcon: Icon(Icons.category_outlined, size: 18, color: AppTheme.textMuted),
            ),
            items: _categories
                .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                .toList(),
            onChanged: (v) => _categoryCtrl.text = v ?? 'Generale',
          ),
          const SizedBox(height: 12),
          // Lingua TTS
          DropdownButtonFormField<String?>(
            value: _selectedLanguage,
            dropdownColor: AppTheme.surfaceHigh,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Lingua (lettura vocale)',
              prefixIcon: Icon(Icons.language, size: 18, color: AppTheme.textMuted),
            ),
            items: _kLanguages.entries
                .map((e) => DropdownMenuItem<String?>(
                      value: e.key,
                      child: Text(e.value),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _selectedLanguage = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: AppTheme.error, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading ? null : _save,
              child: _loading
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.background),
                    )
                  : const Text('Salva'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Inserisci un URL valido');
      return;
    }
    String title = _titleCtrl.text.trim();
    if (title.isEmpty) title = Uri.parse(url).host;

    setState(() { _loading = true; _error = null; });
    try {
      await widget.onSave(title, url, _categoryCtrl.text, _selectedLanguage);
    } catch (e) {
      setState(() => _error = 'Errore: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
