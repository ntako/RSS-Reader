import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../providers/app_providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common_widgets.dart';
import '../article_reader/article_reader_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Article> _results = [];
  bool _searched = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  Future<void> _search(String text) async {
    try {
      final results = await ref.read(databaseProvider).searchArticles(text);
      if (!mounted || text != _controller.text) return;
      setState(() {
        _results = results;
        _searched = text.trim().isNotEmpty;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final feeds = ref.watch(feedsStreamProvider).valueOrNull ?? const <FeedSource>[];
    final feedMap = {for (final f in feeds) f.id: f.title};

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          style: tt.bodyLarge,
          decoration: const InputDecoration(
            hintText: 'Cerca negli articoli…',
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                _controller.clear();
                _search('');
              },
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Errore: $_error', style: const TextStyle(color: AppTheme.error)))
          : _results.isEmpty
              ? Center(
                  child: Text(
                    _searched ? 'Nessun risultato' : 'Cerca per titolo o testo dell\'articolo',
                    style: tt.bodyMedium,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _results.length,
                  itemBuilder: (_, i) {
                    final article = _results[i];
                    return ArticleCard(
                      article: article,
                      feedTitle: feedMap[article.feedId] ?? 'Feed',
                      onTap: () {
                        ref.read(databaseProvider).markAsRead(article.id);
                        Navigator.push(context, MaterialPageRoute(
                          builder: (_) => ArticleReaderScreen(articleId: article.id),
                        ));
                      },
                      onFavoriteToggle: () async {
                        await ref.read(databaseProvider)
                            .toggleFavorite(article.id, !article.isFavorite);
                        _search(_controller.text);
                      },
                    );
                  },
                ),
    );
  }
}
