import 'dart:convert';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'rss_service.dart';

/// Recupera la pagina di un articolo ed estrae il testo del corpo,
/// separando i paragrafi con una riga vuota.
class ArticleExtractor {
  /// Sotto questa lunghezza il risultato è considerato un fallimento
  /// (paywall, pagina renderizzata via JS, blocco anti-bot).
  static const minLength = 300;

  static final _noiseClass = RegExp(
    r'comment|share|social|related|newsletter|cookie|banner|promo|advert|'
    r'sidebar|breadcrumb|recommend|subscribe|paywall|caption|byline',
    caseSensitive: false,
  );

  /// Ritorna il testo dell'articolo, o null se non è stato possibile estrarlo.
  static Future<String?> fetch(String url) async {
    final response = await http.get(Uri.parse(url), headers: {
      'User-Agent': RssService.userAgent,
      'Accept': 'text/html,application/xhtml+xml',
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    return extract(RssService.decodeBody(response));
  }

  static String? extract(String html) {
    final document = html_parser.parse(html);

    // 1. JSON-LD: molti editori pubblicano lì il testo completo.
    final ld = _fromJsonLd(document);
    if (ld != null && ld.length >= minLength && !_looksTruncated(ld)) {
      return _paragraphize(ld);
    }

    // 2. Euristica sul DOM.
    for (final el in document.querySelectorAll(
        'script, style, noscript, iframe, svg, nav, footer, header, aside, form')) {
      el.remove();
    }
    final root = _pickRoot(document);
    if (root == null) return null;

    final blocks = <String>[];
    for (final el in root.querySelectorAll('p, h2, h3, h4, li')) {
      final tag = el.localName;
      if (tag == 'li' && el.querySelector('p') != null) continue;
      if (_hasNoiseAncestor(el, root)) continue;
      final text = el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final isHeading = tag!.startsWith('h');
      if (text.length < (isHeading ? 3 : 20)) continue;
      if (blocks.isNotEmpty && blocks.last == text) continue;
      blocks.add(text);
    }

    final result = blocks.join('\n\n');
    return result.length >= minLength && !_looksTruncated(result) ? result : null;
  }

  /// Le anteprime dei paywall (es. Repubblica: 400 caratteri) finiscono con
  /// i puntini: superano la soglia minima ma non sono l'articolo.
  static bool _looksTruncated(String text) {
    final t = text.trimRight();
    return t.endsWith('…') || t.endsWith('...');
  }

  static const _paragraphTarget = 450;

  /// Il JSON-LD spesso porta il testo in un blocco unico (Sole 24 Ore, Corriere):
  /// senza paragrafi è illeggibile, quindi lo spezza a fine frase ogni ~450
  /// caratteri. I paragrafi sono approssimati, ma il testo non cambia.
  static String _paragraphize(String text) {
    if (text.contains('\n\n') || text.length < 700) return text;
    final sentences = text.split(RegExp(r'(?<=[.!?…»”])\s+(?=[A-ZÀ-ÖØ-Þ«“"])'));
    final paragraphs = <String>[];
    var current = StringBuffer();
    for (final sentence in sentences) {
      if (current.length >= _paragraphTarget) {
        paragraphs.add(current.toString());
        current = StringBuffer();
      }
      if (current.isNotEmpty) current.write(' ');
      current.write(sentence);
    }
    if (current.isNotEmpty) paragraphs.add(current.toString());
    return paragraphs.join('\n\n');
  }

  /// Sceglie il contenitore del corpo: <article> / articleBody se ha abbastanza
  /// testo, altrimenti il nodo con il punteggio di paragrafi più alto.
  static Element? _pickRoot(Document document) {
    for (final sel in ['[itemprop="articleBody"]', 'article']) {
      for (final el in document.querySelectorAll(sel)) {
        if (_paragraphChars(el) >= 400) return el;
      }
    }

    final scores = <Element, double>{};
    for (final p in document.querySelectorAll('p')) {
      final len = p.text.trim().length;
      if (len < 40) continue;
      final parent = p.parent;
      if (parent == null) continue;
      scores[parent] = (scores[parent] ?? 0) + len;
      final grand = parent.parent;
      if (grand != null) scores[grand] = (scores[grand] ?? 0) + len / 2;
    }
    if (scores.isEmpty) return null;
    return scores.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  static int _paragraphChars(Element el) => el
      .querySelectorAll('p')
      .map((p) => p.text.trim())
      .where((t) => t.length >= 40)
      .fold(0, (sum, t) => sum + t.length);

  static bool _hasNoiseAncestor(Element el, Element root) {
    Element? cur = el;
    while (cur != null && cur != root) {
      final marker = '${cur.className} ${cur.id}';
      if (marker.trim().isNotEmpty && _noiseClass.hasMatch(marker)) return true;
      cur = cur.parent;
    }
    return false;
  }

  static String? _fromJsonLd(Document document) {
    for (final script
        in document.querySelectorAll('script[type="application/ld+json"]')) {
      try {
        final body = _findArticleBody(jsonDecode(script.text));
        if (body != null) {
          final text = html_parser.parse(body).body?.text ?? body;
          return text
              .replaceAll(RegExp(r'[ \t]+'), ' ')
              .replaceAll(RegExp(r'\s*\n\s*'), '\n\n')
              .trim();
        }
      } catch (_) {}
    }
    return null;
  }

  static String? _findArticleBody(dynamic node) {
    if (node is Map) {
      final body = node['articleBody'];
      if (body is String && body.isNotEmpty) return body;
      for (final v in node.values) {
        final found = _findArticleBody(v);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final v in node) {
        final found = _findArticleBody(v);
        if (found != null) return found;
      }
    }
    return null;
  }
}
