import 'package:flutter_test/flutter_test.dart';
import 'package:rss_reader/services/article_extractor.dart';
import 'package:rss_reader/services/rss_service.dart';

void main() {
  final para = 'Questo è un paragrafo abbastanza lungo per essere considerato testo di un articolo vero. ' * 2;

  test('estrae il corpo e scarta menu e correlati', () {
    final html = '''
<html><body>
<nav><p>${'Menu di navigazione molto lungo ' * 5}</p></nav>
<div class="page"><div class="body">
<h2>Sottotitolo</h2><p>Uno. $para</p><p>Due. $para</p><p>Tre. $para</p>
<div class="related-posts"><p>Leggi anche: un altro articolo correlato qui</p></div>
</div></div></body></html>''';
    final out = ArticleExtractor.extract(html)!;
    expect(out, contains('Sottotitolo'));
    expect(out, isNot(contains('Menu di navigazione')));
    expect(out, isNot(contains('Leggi anche')));
    expect(out.split('\n\n').length, 4);
  });

  test('usa articleBody del JSON-LD', () {
    final body = 'Testo integrale dell\\u0027articolo. ' * 30;
    final html = '<html><head><script type="application/ld+json">{"@graph":[{"articleBody":"$body"}]}</script></head><body></body></html>';
    expect(ArticleExtractor.extract(html), contains('Testo integrale'));
  });

  test('pagina con poco testo (paywall) ritorna null', () {
    expect(ArticleExtractor.extract('<html><body><article><p>Solo un titolo breve.</p></article></body></html>'), isNull);
  });

  test('needsFullText e articleText', () {
    expect(RssService.needsFullText(null, 'breve'), isTrue);
    expect(RssService.needsFullText('pieno', 'breve'), isFalse);
    expect(RssService.articleText('a\n\nb', '<p>x</p>'), 'a\n\nb');
    expect(RssService.articleText(null, '<p>x</p>'), 'x');
  });

  test('htmlToParagraphs mantiene i paragrafi', () {
    expect(RssService.htmlToParagraphs('<p>Uno</p><p>Due</p>'), 'Uno\n\nDue');
  });
}
