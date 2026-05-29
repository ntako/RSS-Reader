import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme/app_theme.dart';
import '../../database/database.dart';
import '../../providers/app_providers.dart';
import '../../services/gemma_service.dart';
import '../../services/tts_service.dart';
import '../../services/rss_service.dart';
import '../../widgets/common_widgets.dart';
import 'package:intl/intl.dart';

class ArticleReaderScreen extends ConsumerStatefulWidget {
  final int articleId;
  const ArticleReaderScreen({super.key, required this.articleId});

  @override
  ConsumerState<ArticleReaderScreen> createState() => _ArticleReaderScreenState();
}

class _ArticleReaderScreenState extends ConsumerState<ArticleReaderScreen> {
  Article? _article;
  String? _feedTitle;
  String _feedLanguage = 'it-IT';
  bool _isLoadingSummary = false;
  TtsState _ttsState = TtsState.stopped;
  double _ttsSpeed = 0.5;
  bool _showSummary = false;
  double _fontSize = 16;

  @override
  void initState() {
    super.initState();
    _loadArticle();
    _initTts();
  }

  Future<void> _loadArticle() async {
    final db = ref.read(databaseProvider);
    final article = await db.getArticleById(widget.articleId);
    if (article == null) return;
    
    // Carica il titolo del feed
    final feeds = await db.getAllFeeds();
    final feed = feeds.where((f) => f.id == article.feedId).firstOrNull;

    setState(() {
      _article = article;
      _feedTitle = feed?.title;
      _feedLanguage = langToTtsLocale(feed?.language);
    });
  }

  void _initTts() {
    final tts = ref.read(ttsServiceProvider);
    tts.onStateChange = (state) {
      if (mounted) setState(() => _ttsState = state);
    };
  }

  @override
  void dispose() {
    ref.read(ttsServiceProvider).stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_article == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final article = _article!;
    final tt = Theme.of(context).textTheme;
    final readableContent = RssService.extractReadableText(
      article.content ?? article.description,
    );

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // App Bar con immagine
          SliverAppBar(
            expandedHeight: article.imageUrl != null ? 240 : 0,
            pinned: true,
            backgroundColor: AppTheme.background,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                icon: Icon(
                  article.isFavorite ? Icons.bookmark : Icons.bookmark_border,
                  color: article.isFavorite ? AppTheme.accent : AppTheme.textSecondary,
                ),
                onPressed: () {
                  ref.read(databaseProvider)
                      .toggleFavorite(article.id, !article.isFavorite);
                  setState(() {
                    _article = article.copyWith(isFavorite: !article.isFavorite);
                  });
                },
              ),
              IconButton(
                icon: const Icon(Icons.open_in_browser, size: 20),
                onPressed: () => _openInBrowser(article.url),
              ),
              // Font size
              PopupMenuButton<double>(
                icon: const Icon(Icons.text_fields, size: 20),
                color: AppTheme.surfaceHigh,
                onSelected: (v) => setState(() => _fontSize = v),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 13, child: Text('Piccolo', style: TextStyle(color: AppTheme.textPrimary))),
                  const PopupMenuItem(value: 16, child: Text('Medio', style: TextStyle(color: AppTheme.textPrimary))),
                  const PopupMenuItem(value: 19, child: Text('Grande', style: TextStyle(color: AppTheme.textPrimary))),
                  const PopupMenuItem(value: 22, child: Text('Molto grande', style: TextStyle(color: AppTheme.textPrimary))),
                ],
              ),
            ],
            flexibleSpace: article.imageUrl != null
                ? FlexibleSpaceBar(
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.network(article.imageUrl!, fit: BoxFit.cover),
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                AppTheme.background.withOpacity(0.9),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : null,
          ),

          // Contenuto articolo
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Meta info
                Row(
                  children: [
                    if (_feedTitle != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(_feedTitle!,
                            style: tt.labelLarge?.copyWith(fontSize: 11)),
                      ),
                    const Spacer(),
                    if (article.publishedAt != null)
                      Text(
                        DateFormat('d MMMM yyyy, HH:mm', 'it').format(article.publishedAt!),
                        style: tt.bodySmall,
                      ),
                  ],
                ),
                const SizedBox(height: 14),

                // Titolo
                Text(article.title, style: tt.displayMedium),
                if (article.author != null) ...[
                  const SizedBox(height: 8),
                  Text('di ${article.author}', style: tt.bodySmall?.copyWith(
                    color: AppTheme.textSecondary, fontStyle: FontStyle.italic,
                  )),
                ],
                const SizedBox(height: 20),

                // Pulsante riassunto AI
                _AiSummarySection(
                  article: article,
                  isLoading: _isLoadingSummary,
                  showSummary: _showSummary,
                  content: readableContent,
                  feedLanguage: _feedLanguage,
                  onToggle: () => setState(() => _showSummary = !_showSummary),
                  onGenerate: _generateSummary,
                  onReadSummary: () => _toggleTts(
                    article.aiSummary ?? '', article.title,
                  ),
                ),

                const SizedBox(height: 20),
                const Divider(color: AppTheme.divider),
                const SizedBox(height: 16),

                // TTS button in-content
                _TtsInlineButton(
                  ttsState: _ttsState,
                  onTap: () => _toggleTts(readableContent, article.title),
                ),
                const SizedBox(height: 20),

                // Testo dell'articolo
                if (readableContent.isNotEmpty)
                  SelectableText(
                    readableContent,
                    style: tt.bodyLarge?.copyWith(fontSize: _fontSize, height: 1.8),
                  )
                else
                  Text(
                    'Il contenuto completo non è disponibile.\nAprilo nel browser per leggerlo.',
                    style: tt.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic, color: AppTheme.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 40),

                // Open in browser
                Center(
                  child: OutlinedButton.icon(
                    onPressed: () => _openInBrowser(article.url),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.accent,
                      side: const BorderSide(color: AppTheme.accent),
                    ),
                    icon: const Icon(Icons.open_in_browser, size: 16),
                    label: const Text('Apri articolo originale'),
                  ),
                ),
                const SizedBox(height: 80),
              ]),
            ),
          ),
        ],
      ),

      // TTS player bar
      bottomNavigationBar: _ttsState != TtsState.stopped
          ? TtsPlayerBar(
              isPlaying: _ttsState == TtsState.playing,
              isPaused: _ttsState == TtsState.paused,
              articleTitle: article.title,
              speed: _ttsSpeed,
              onSpeedChanged: (v) {
                setState(() => _ttsSpeed = v);
                ref.read(ttsServiceProvider).setSpeechRate(v);
              },
              onPlayPause: () => _toggleTts(readableContent, article.title),
              onStop: () => ref.read(ttsServiceProvider).stop(),
            )
          : null,
    );
  }

  Future<void> _toggleTts(String content, String title) async {
    final tts = ref.read(ttsServiceProvider);
    final text = content.isNotEmpty ? content : title;

    if (_ttsState == TtsState.playing) {
      await tts.pause();
    } else if (_ttsState == TtsState.paused) {
      await tts.speak(text, language: _feedLanguage);
    } else {
      await tts.setSpeechRate(_ttsSpeed);
      await tts.speak(text, language: _feedLanguage);
    }
  }

  Future<void> _generateSummary() async {
    if (_article == null) return;
    final content = RssService.extractReadableText(
      _article!.content ?? _article!.description,
    );
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun contenuto da riassumere'),
            backgroundColor: AppTheme.error),
      );
      return;
    }

    setState(() => _isLoadingSummary = true);
    try {
      final gemma = ref.read(gemmaServiceProvider);
      final summary = await gemma.summarize(_article!.title, content);
      if (summary != null) {
        await ref.read(databaseProvider).saveAiSummary(_article!.id, summary);
        await _loadArticle(); // ricarica con summary
        setState(() => _showSummary = true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore Gemma: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingSummary = false);
    }
  }

  Future<void> _openInBrowser(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

// ── AI Summary section ────────────────────────────────────────────────────────

class _AiSummarySection extends ConsumerWidget {
  final Article article;
  final bool isLoading;
  final bool showSummary;
  final String content;
  final String feedLanguage;
  final VoidCallback onToggle;
  final VoidCallback onGenerate;
  final VoidCallback onReadSummary;

  const _AiSummarySection({
    required this.article,
    required this.isLoading,
    required this.showSummary,
    required this.content,
    required this.feedLanguage,
    required this.onToggle,
    required this.onGenerate,
    required this.onReadSummary,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    final (modelState, progress) = ref.watch(gemmaModelProvider);
    final ttsState = ref.watch(ttsStateProvider);
    final isSummaryPlaying = ttsState != TtsState.stopped && article.aiSummary != null;

    // Modello non caricato → rimanda a Impostazioni
    if (modelState == GemmaModelState.notDownloaded) {
      return GestureDetector(
        onTap: () {
          Navigator.of(context).popUntil((r) => r.isFirst);
          ref.read(homeTabProvider.notifier).state = 3;
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.surfaceHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.accent.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome, size: 16, color: AppTheme.accent),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Modello Gemma non caricato',
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Vai in Impostazioni → "Scegli file locale" se hai già il .bin',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 13, color: AppTheme.accent),
            ],
          ),
        ),
      );
    }

    // Download in corso
    if (modelState == GemmaModelState.downloading) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.accent.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.accent.withOpacity(0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.download_outlined, size: 14, color: AppTheme.accent),
                const SizedBox(width: 8),
                const Text('Download Gemma…',
                    style: TextStyle(color: AppTheme.accentSoft, fontSize: 13)),
                const Spacer(),
                Text('${(progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: AppTheme.accent, fontSize: 12,
                        fontWeight: FontWeight.w600)),
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
          ],
        ),
      );
    }

    if (modelState == GemmaModelState.checking) return const SizedBox.shrink();

    // Modello pronto — elaborazione in corso
    if (isLoading) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.accent.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.accent.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent)),
            const SizedBox(width: 12),
            Text('Gemma sta elaborando il riassunto…',
                style: tt.bodySmall?.copyWith(color: AppTheme.accentSoft)),
          ],
        ),
      );
    }

    // Riassunto disponibile
    if (article.aiSummary != null) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.accent.withOpacity(0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.accent.withOpacity(0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome, size: 14, color: AppTheme.accent),
                const SizedBox(width: 6),
                Text('Riassunto Gemma AI', style: tt.labelLarge),
                const Spacer(),
                // Ascolta riassunto
                GestureDetector(
                  onTap: onReadSummary,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isSummaryPlaying
                          ? AppTheme.accent.withOpacity(0.2)
                          : AppTheme.surface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isSummaryPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 14,
                          color: AppTheme.accent,
                        ),
                        const SizedBox(width: 4),
                        Text('Ascolta',
                            style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.accent,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Espandi/comprimi
                GestureDetector(
                  onTap: onToggle,
                  child: Icon(
                    showSummary ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: AppTheme.accent,
                  ),
                ),
              ],
            ),
            if (showSummary) ...[
              const SizedBox(height: 10),
              Text(article.aiSummary!,
                  style: tt.bodyMedium?.copyWith(
                      color: AppTheme.textPrimary, height: 1.7)),
            ],
          ],
        ),
      );
    }

    // Nessun riassunto ancora — pulsante genera
    return GestureDetector(
      onTap: content.isNotEmpty ? onGenerate : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.divider),
        ),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome, size: 16, color: AppTheme.textMuted),
            const SizedBox(width: 10),
            Text(
              content.isNotEmpty
                  ? 'Genera riassunto con Gemma'
                  : 'Contenuto non disponibile per riassunto',
              style: tt.bodySmall?.copyWith(
                color: content.isNotEmpty ? AppTheme.textSecondary : AppTheme.textMuted,
              ),
            ),
            const Spacer(),
            if (content.isNotEmpty)
              const Icon(Icons.chevron_right, size: 16, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }
}

// ── TTS inline button ─────────────────────────────────────────────────────────

class _TtsInlineButton extends StatelessWidget {
  final TtsState ttsState;
  final VoidCallback onTap;

  const _TtsInlineButton({required this.ttsState, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isActive = ttsState == TtsState.playing;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? AppTheme.accent.withOpacity(0.12) : AppTheme.surfaceHigh,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: isActive ? AppTheme.accent : AppTheme.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? Icons.pause_circle_outline : Icons.play_circle_outline,
              size: 20,
              color: isActive ? AppTheme.accent : AppTheme.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              isActive ? 'Pausa lettura' : 'Ascolta articolo',
              style: TextStyle(
                fontSize: 13,
                color: isActive ? AppTheme.accent : AppTheme.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
