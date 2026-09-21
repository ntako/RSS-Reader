import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import '../database/database.dart';
import '../providers/app_providers.dart';
import '../services/tts_service.dart';
import '../widgets/common_widgets.dart';
import 'feed_manager/feed_manager_screen.dart';
import 'article_list/article_list_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Il task in background scrive nel database da un altro isolate: le query
  /// in tempo reale di Drift non lo sanno e la lista resterebbe vecchia.
  /// Al ritorno in primo piano si dichiarano aggiornate le tabelle.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final db = ref.read(databaseProvider);
    db.markTablesUpdated([db.articles, db.feedSources]);
  }

  @override
  Widget build(BuildContext context) {
    // Navigazione programmatica da altre screen (es. redirect a Impostazioni)
    ref.listen(homeTabProvider, (_, newTab) {
      if (mounted) setState(() => _tab = newTab);
    });

    final feedsAsync = ref.watch(feedsStreamProvider);

    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          // Tab 0: Tutti gli articoli
          const ArticleListScreen(feedId: null, title: 'Tutte le notizie'),
          // Tab 1: Feed per categoria (usa la sidebar)
          _FeedBrowseTab(),
          // Tab 2: Preferiti
          const ArticleListScreen(feedId: -1, title: 'Preferiti'),
          // Tab 3: Gestione fonti
          const FeedManagerScreen(),
        ],
      ),
      bottomNavigationBar: _BottomBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        feedsAsync: feedsAsync,
      ),
    );
  }
}

// ── Bottom bar con player TTS globale ────────────────────────────────────────

class _BottomBar extends ConsumerStatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final AsyncValue<List<FeedSource>> feedsAsync;

  const _BottomBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.feedsAsync,
  });

  @override
  ConsumerState<_BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends ConsumerState<_BottomBar> {
  double _speed = 0.5;

  @override
  Widget build(BuildContext context) {
    final ttsState = ref.watch(ttsStateProvider);
    final queue = ref.watch(ttsQueueProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Player globale — visibile quando la coda è attiva
        if (queue.hasQueue || ttsState != TtsState.stopped)
          TtsPlayerBar(
            isPlaying: ttsState == TtsState.playing,
            isPaused: ttsState == TtsState.paused,
            articleTitle: queue.currentTitle ?? '',
            speed: _speed,
            onSpeedChanged: (v) {
              setState(() => _speed = v);
              ref.read(ttsServiceProvider).setSpeechRate(v);
            },
            onPlayPause: () {
              final tts = ref.read(ttsServiceProvider);
              if (ttsState == TtsState.playing) {
                tts.pause();
              } else {
                // Riprendi o riavvia
                tts.setSpeechRate(_speed);
              }
            },
            onStop: () {
              ref.read(ttsServiceProvider).stop();
              ref.read(ttsStateProvider.notifier).state = TtsState.stopped;
            },
          ),
        NavigationBar(
          selectedIndex: widget.selectedIndex,
          onDestinationSelected: widget.onDestinationSelected,
          backgroundColor: AppTheme.surface,
          indicatorColor: AppTheme.accent.withOpacity(0.15),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home, color: AppTheme.accent),
              label: 'Tutte',
            ),
            NavigationDestination(
              icon: widget.feedsAsync.when(
                data: (feeds) => Badge(
                  label: Text('${feeds.length}'),
                  backgroundColor: AppTheme.accent,
                  textColor: AppTheme.background,
                  isLabelVisible: feeds.isNotEmpty,
                  child: const Icon(Icons.rss_feed_outlined),
                ),
                loading: () => const Icon(Icons.rss_feed_outlined),
                error: (_, __) => const Icon(Icons.rss_feed_outlined),
              ),
              selectedIcon: const Icon(Icons.rss_feed, color: AppTheme.accent),
              label: 'Fonti',
            ),
            const NavigationDestination(
              icon: Icon(Icons.bookmark_border_outlined),
              selectedIcon: Icon(Icons.bookmark, color: AppTheme.accent),
              label: 'Salvati',
            ),
            const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings, color: AppTheme.accent),
              label: 'Impostazioni',
            ),
          ],
        ),
      ],
    );
  }
}

// ── Feed browse tab ───────────────────────────────────────────────────────────

class _FeedBrowseTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_FeedBrowseTab> createState() => _FeedBrowseTabState();
}

class _FeedBrowseTabState extends ConsumerState<_FeedBrowseTab> {
  int? _selectedFeedId;
  String _selectedFeedTitle = 'Tutte le fonti';

  @override
  Widget build(BuildContext context) {
    final feedsAsync = ref.watch(feedsStreamProvider);
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(_selectedFeedTitle)),
      body: Row(
        children: [
          // Sidebar fonti
          Container(
            width: 200,
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: AppTheme.divider)),
            ),
            child: feedsAsync.when(
              data: (feeds) => ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _SidebarItem(
                    title: 'Tutte',
                    icon: Icons.all_inclusive,
                    isSelected: _selectedFeedId == null,
                    onTap: () => setState(() {
                      _selectedFeedId = null;
                      _selectedFeedTitle = 'Tutte le fonti';
                    }),
                  ),
                  const Divider(indent: 12, endIndent: 12),
                  ...feeds.map((f) => _SidebarItem(
                    title: f.title,
                    icon: Icons.rss_feed,
                    isSelected: _selectedFeedId == f.id,
                    onTap: () => setState(() {
                      _selectedFeedId = f.id;
                      _selectedFeedTitle = f.title;
                    }),
                  )),
                ],
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const SizedBox(),
            ),
          ),
          // Lista articoli
          Expanded(
            child: ArticleListScreen(
              feedId: _selectedFeedId,
              title: _selectedFeedTitle,
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.title,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.accent.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              icon, size: 16,
              color: isSelected ? AppTheme.accent : AppTheme.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected ? AppTheme.accent : AppTheme.textSecondary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
