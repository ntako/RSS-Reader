import 'package:flutter_test/flutter_test.dart';
import 'package:rss_reader/database/database.dart';
import 'package:rss_reader/services/opml_service.dart';

FeedSource feed(String title, String url, String cat, [String? lang]) => FeedSource(
      id: 1, title: title, url: url, category: cat, language: lang,
      isActive: true, notify: false, createdAt: DateTime(2026),
    );

void main() {
  test('export → parse conserva titolo, url, categoria e lingua', () {
    final xml = OpmlService.export([
      feed('ANSA & Co', 'https://a.it/rss?x=1&y=2', 'Generale', 'it'),
      feed('Verge', 'https://v.com/rss', 'Tecnologia', 'en'),
    ]);
    final back = OpmlService.parse(xml);
    expect(back.length, 2);
    expect(back[0].title, 'ANSA & Co');
    expect(back[0].url, 'https://a.it/rss?x=1&y=2');
    expect(back[0].category, 'Generale');
    expect(back[1].language, 'en');
  });

  test('legge OPML annidato di altri lettori', () {
    const opml = '''<?xml version="1.0"?>
<opml version="1.0"><head/><body>
  <outline text="Notizie"><outline text="Uno" xmlUrl="https://u.it/f"/>
    <outline text="Sotto"><outline title="Due" xmlUrl="https://d.it/f"/></outline></outline>
  <outline text="Senza cat" xmlUrl="https://s.it/f"/>
</body></opml>''';
    final feeds = OpmlService.parse(opml);
    expect(feeds.map((f) => f.category), ['Notizie', 'Sotto', 'Generale']);
    expect(feeds[1].title, 'Due');
  });

  test('file non OPML lancia FormatException', () {
    expect(() => OpmlService.parse('<rss/>'), throwsFormatException);
    expect(() => OpmlService.parse('non xml'), throwsFormatException);
  });
}
