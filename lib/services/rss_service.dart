import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:webfeed_plus/webfeed_plus.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:drift/drift.dart';

import '../database/database.dart';

class RssService {
  static const userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36 RssReader/1.0';

  final AppDatabase _db;

  RssService(this._db);

  /// Recupera e salva gli articoli di un feed. Ritorna il numero di nuovi articoli.
  Future<int> fetchFeed(FeedSource source) async {
    try {
      final response = await http.get(Uri.parse(source.url), headers: {
        'User-Agent': userAgent,
        'Accept': 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*',
        if (source.etag != null) 'If-None-Match': source.etag!,
        if (source.lastModified != null) 'If-Modified-Since': source.lastModified!,
      }).timeout(const Duration(seconds: 15));

      // Feed invariato: niente da scaricare né da parsare.
      if (response.statusCode == 304) {
        await _db.updateFeed(source.copyWith(lastFetched: Value(DateTime.now())));
        return 0;
      }
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');

      final body = decodeBody(response);
      List<_ParsedItem> items = [];
      var updated = source;

      // Prova RSS poi Atom
      try {
        final feed = RssFeed.parse(body);
        items = _parseRssItems(feed.items ?? []);
        // Aggiorna metadati del feed se non impostati
        if (source.description == null && feed.description != null) {
          updated = updated.copyWith(description: Value(feed.description));
        }
        if (source.language == null && feed.language != null) {
          updated = updated.copyWith(language: Value(feed.language));
        }
      } catch (_) {
        try {
          final feed = AtomFeed.parse(body);
          items = _parseAtomItems(feed.items ?? []);
        } catch (e) {
          throw Exception('Impossibile parsare il feed: $e');
        }
      }

      final companions = [
        for (final item in items)
          if (item.url.isNotEmpty && item.url.length <= 500)
            ArticlesCompanion.insert(
              feedId: source.id,
              guid: _clip(item.guid, 500),
              title: _clip(item.title, 500),
              url: item.url,
              author: Value(item.author),
              description: Value(item.description),
              content: Value(item.content),
              imageUrl: Value(item.imageUrl),
              publishedAt: Value(item.publishedAt),
            ),
      ];
      final newCount = await _db.insertNewArticles(source.id, companions);

      // Aggiorna lastFetched
      await _db.updateFeed(updated.copyWith(
        lastFetched: Value(DateTime.now()),
        etag: Value(response.headers['etag']),
        lastModified: Value(response.headers['last-modified']),
      ));

      return newCount;
    } catch (e) {
      rethrow;
    }
  }

  static String _clip(String s, int max) => s.length > max ? s.substring(0, max) : s;

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

    await _db.pruneOldArticles();
    return Map.fromEntries(results);
  }

  /// Decodifica il body HTTP gestendo il disallineamento charset server/contenuto.
  /// Molti feed dichiarano ISO-8859-1 ma inviano UTF-8 → caractteri corrotti.
  static String decodeBody(http.Response response) {
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

  /// Sotto questa lunghezza l'estratto del feed è considerato incompleto
  /// e vale la pena scaricare la pagina dell'articolo.
  static const _fullTextThreshold = 1500;

  static bool needsFullText(String? content, String? description) =>
      (content == null || content.isEmpty) &&
      (description?.length ?? 0) < _fullTextThreshold;

  /// Testo da mostrare/leggere/riassumere: il testo pieno se disponibile,
  /// altrimenti l'estratto del feed.
  static String articleText(String? content, String? description) =>
      (content != null && content.isNotEmpty)
          ? content
          : extractReadableText(description);

  /// Converte HTML in testo con i paragrafi separati da una riga vuota.
  static String htmlToParagraphs(String? htmlContent) {
    if (htmlContent == null || htmlContent.isEmpty) return '';
    final document = html_parser.parse(htmlContent);
    for (final el in document.querySelectorAll('script, style')) {
      el.remove();
    }
    final blocks = <String>[];
    for (final el in document.querySelectorAll('p, h1, h2, h3, h4, li')) {
      if (el.localName == 'li' && el.querySelector('p') != null) continue;
      final text = el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) blocks.add(text);
    }
    if (blocks.isEmpty) return extractReadableText(htmlContent);
    return blocks.join('\n\n');
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
        content: _fullContent(item.content?.value, item.description),
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
        description: _stripHtmlTags(item.summary ?? content),
        content: _fullContent(item.content, item.summary),
        imageUrl: imageUrl,
        publishedAt: item.updated,
      );
    }).toList();
  }

  /// Usa content:encoded (o <content> Atom) solo se contiene davvero più
  /// testo dell'estratto; altrimenti ritorna null e si scaricherà la pagina.
  String? _fullContent(String? fullHtml, String? excerptHtml) {
    if (fullHtml == null || fullHtml.isEmpty) return null;
    final full = htmlToParagraphs(fullHtml);
    final excerpt = _stripHtmlTags(excerptHtml);
    return full.length > excerpt.length + 200 ? full : null;
  }

  /// Testo dell'HTML su una riga; la fine di ogni blocco vale come spazio,
  /// altrimenti "<p>uno</p><p>due</p>" diventerebbe "unodue".
  String _stripHtmlTags(String? html) {
    if (html == null) return '';
    final spaced = html.replaceAll(
      RegExp(r'</(p|div|li|h[1-6])>|<br\s*/?>', caseSensitive: false), ' ');
    final text = html_parser.parse(spaced).body?.text ?? '';
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
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
  final String? content;
  final String? imageUrl;
  final DateTime? publishedAt;

  _ParsedItem({
    required this.guid,
    required this.title,
    required this.url,
    this.author,
    required this.description,
    this.content,
    this.imageUrl,
    this.publishedAt,
  });
}
