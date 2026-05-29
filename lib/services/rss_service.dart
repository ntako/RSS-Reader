import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:webfeed/webfeed.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:drift/drift.dart';

import '../database/database.dart';

class RssService {
  final AppDatabase _db;

  RssService(this._db);

  /// Recupera e salva gli articoli di un feed. Ritorna il numero di nuovi articoli.
  Future<int> fetchFeed(FeedSource source) async {
    try {
      final response = await http
          .get(Uri.parse(source.url), headers: {'User-Agent': 'RssReader/1.0'})
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');

      final body = _decodeBody(response);
      List<_ParsedItem> items = [];

      // Prova RSS poi Atom
      try {
        final feed = RssFeed.parse(body);
        items = _parseRssItems(feed.items ?? []);
        // Aggiorna metadati del feed se non impostati
        FeedSource updated = source;
        if (source.description == null && feed.description != null) {
          updated = updated.copyWith(description: Value(feed.description));
        }
        if (source.language == null && feed.language != null) {
          updated = updated.copyWith(language: Value(feed.language));
        }
        if (updated != source) await _db.updateFeed(updated);
      } catch (_) {
        try {
          final feed = AtomFeed.parse(body);
          items = _parseAtomItems(feed.items ?? []);
        } catch (e) {
          throw Exception('Impossibile parsare il feed: $e');
        }
      }

      int newCount = 0;
      for (final item in items) {
        final companion = ArticlesCompanion.insert(
          feedId: source.id,
          guid: item.guid,
          title: item.title,
          url: item.url,
          author: Value(item.author),
          description: Value(item.description),
          imageUrl: Value(item.imageUrl),
          publishedAt: Value(item.publishedAt),
        );
        final isNew = await _db.upsertArticle(companion);
        if (isNew) newCount++;
      }

      // Aggiorna lastFetched
      await _db.updateFeed(
        source.copyWith(lastFetched: Value(DateTime.now())),
      );

      return newCount;
    } catch (e) {
      rethrow;
    }
  }

  /// Fetch di tutti i feed attivi in parallelo
  Future<Map<int, dynamic>> fetchAllFeeds() async {
    final feeds = await _db.getAllFeeds();
    final active = feeds.where((f) => f.isActive).toList();

    final results = await Future.wait(
      active.map((feed) async {
        try {
          final count = await fetchFeed(feed);
          return MapEntry(feed.id, count);
        } catch (e) {
          return MapEntry(feed.id, e);
        }
      }),
    );

    return Map.fromEntries(results);
  }

  /// Decodifica il body HTTP gestendo il disallineamento charset server/contenuto.
  /// Molti feed dichiarano ISO-8859-1 ma inviano UTF-8 → caractteri corrotti.
  static String _decodeBody(http.Response response) {
    final bytes = response.bodyBytes;

    // 1. Prova UTF-8 strict: se il feed è davvero UTF-8 funziona subito
    try {
      return utf8.decode(bytes);
    } catch (_) {}

    // 2. Controlla se il server dichiara un charset diverso
    final ct = response.headers['content-type'] ?? '';
    final charsetMatch = RegExp(r'charset=([^\s;]+)', caseSensitive: false).firstMatch(ct);
    final charset = charsetMatch?.group(1)?.toLowerCase() ?? '';

    if (charset.contains('1252') || charset.contains('windows')) {
      return latin1.decode(bytes);
    }

    // 3. Fallback: latin1 (mai lancia eccezioni)
    return latin1.decode(bytes);
  }

  /// Estrae il testo leggibile da HTML
  static String extractReadableText(String? htmlContent) {
    if (htmlContent == null || htmlContent.isEmpty) return '';
    final document = html_parser.parse(htmlContent);
    // Rimuovi script e style
    for (final el in document.querySelectorAll('script, style, nav, footer, header')) {
      el.remove();
    }
    final text = document.body?.text ?? '';
    // Normalizza spazi multipli
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ── Parsing helpers ───────────────────────────────────────────────────────

  List<_ParsedItem> _parseRssItems(List<RssItem> items) {
    return items.map((item) {
      final guid = item.guid ?? item.link ?? item.title ?? DateTime.now().toIso8601String();
      final imageUrl = item.enclosure?.url ?? _extractImageFromHtml(item.description);
      return _ParsedItem(
        guid: guid,
        title: item.title ?? 'Senza titolo',
        url: item.link ?? '',
        author: item.author ?? item.dc?.creator,
        description: _stripHtmlTags(item.description),
        imageUrl: imageUrl,
        publishedAt: item.pubDate,
      );
    }).toList();
  }

  List<_ParsedItem> _parseAtomItems(List<AtomItem> items) {
    return items.map((item) {
      final guid = item.id ?? item.links?.firstOrNull?.href ?? item.title ?? DateTime.now().toIso8601String();
      final content = item.content ?? item.summary;
      final imageUrl = _extractImageFromHtml(content);
      return _ParsedItem(
        guid: guid,
        title: item.title ?? 'Senza titolo',
        url: item.links?.firstOrNull?.href ?? '',
        author: item.authors?.firstOrNull?.name,
        description: _stripHtmlTags(content),
        imageUrl: imageUrl,
        publishedAt: item.updated,
      );
    }).toList();
  }

  String _stripHtmlTags(String? html) {
    if (html == null) return '';
    return html_parser.parse(html).body?.text.trim() ?? '';
  }

  String? _extractImageFromHtml(String? html) {
    if (html == null) return null;
    final doc = html_parser.parse(html);
    final img = doc.querySelector('img');
    return img?.attributes['src'];
  }
}

class _ParsedItem {
  final String guid;
  final String title;
  final String url;
  final String? author;
  final String description;
  final String? imageUrl;
  final DateTime? publishedAt;

  _ParsedItem({
    required this.guid,
    required this.title,
    required this.url,
    this.author,
    required this.description,
    this.imageUrl,
    this.publishedAt,
  });
}
