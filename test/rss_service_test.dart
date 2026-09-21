import 'dart:ffi';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rss_reader/database/database.dart';
import 'package:rss_reader/services/rss_service.dart';
import 'package:sqlite3/open.dart';

const _rss = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel><title>Test</title><description>Feed di prova</description><language>it</language>
<item><title>Con testo completo</title><link>https://t.it/1</link><guid>g1</guid>
  <dc:creator>Mario</dc:creator><pubDate>Sat, 19 Sep 2026 08:00:00 GMT</pubDate>
  <description>Breve estratto.</description>
  <content:encoded><![CDATA[<p>Primo paragrafo dell'articolo intero, abbastanza lungo da superare l'estratto di molto.</p><p>Secondo paragrafo con altro testo utile per superare la soglia di duecento caratteri aggiuntivi rispetto all'estratto breve.</p><p>Terzo paragrafo.</p>]]></content:encoded></item>
<item><title>Solo estratto</title><link>https://t.it/2</link><guid>g2</guid>
  <pubDate>Sat, 19 Sep 2026 07:00:00 GMT</pubDate><description>&lt;p&gt;Solo poche&lt;/p&gt;&lt;p&gt;righe.&lt;/p&gt;</description></item>
</channel></rss>''';

const _atom = '''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom test</title><updated>2026-09-19T08:00:00Z</updated>
<entry><title>Voce Atom</title><id>tag:a,1</id><link href="https://a.it/1"/><updated>2026-09-19T08:00:00Z</updated>
<author><name>Anna</name></author>
<summary>Riassunto breve.</summary>
<content type="html">&lt;p&gt;Contenuto completo della voce Atom, molto più lungo del riassunto, con abbastanza testo per essere considerato pieno. Continua ancora con altre frasi per superare la soglia di duecento caratteri rispetto al riassunto, così il testo della voce viene salvato come contenuto pieno.&lt;/p&gt;&lt;p&gt;Secondo.&lt;/p&gt;</content></entry>
</feed>''';

void main() {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  }

  late HttpServer server;
  late AppDatabase db;
  late RssService svc;
  final requests = <HttpRequest>[];
  const etag = '"v1"';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    svc = RssService(db);
    requests.clear();
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) {
      requests.add(req);
      if (req.uri.path == '/rss') {
        if (req.headers.value('if-none-match') == etag) {
          req.response.statusCode = 304;
        } else {
          req.response.headers
            ..contentType = ContentType('application', 'rss+xml', charset: 'utf-8')
            ..set('ETag', etag)
            ..set('Last-Modified', 'Sat, 19 Sep 2026 08:00:00 GMT');
          req.response.write(_rss);
        }
      } else {
        req.response.headers.contentType = ContentType('application', 'atom+xml', charset: 'utf-8');
        req.response.write(_atom);
      }
      req.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await db.close();
  });

  Future<FeedSource> addFeed(String path) async {
    final id = await db.insertFeed(FeedSourcesCompanion.insert(
        title: 'T', url: 'http://127.0.0.1:${server.port}$path'));
    return (await db.getAllFeeds()).firstWhere((f) => f.id == id);
  }

  test('RSS: articoli, autore, metadati feed e content:encoded', () async {
    final feed = await addFeed('/rss');
    expect(await svc.fetchFeed(feed), 2);

    final articles = await db.watchArticlesByFeed(feed.id).first;
    final full = articles.firstWhere((a) => a.guid == 'g1');
    expect(full.author, 'Mario');
    expect(full.description, 'Breve estratto.');
    expect(full.content, contains('Primo paragrafo'));
    expect(full.content, contains('\n\n')); // paragrafi separati
    final excerpt = articles.firstWhere((a) => a.guid == 'g2');
    expect(excerpt.content, isNull);
    expect(excerpt.description, 'Solo poche righe.'); // paragrafi non incollati

    final updated = (await db.getAllFeeds()).single;
    expect(updated.language, 'it');
    expect(updated.description, 'Feed di prova'); // non sovrascritto a fine fetch
    expect(updated.etag, etag);
    expect(updated.lastModified, isNotNull);
  });

  test('secondo fetch: invia If-None-Match, riceve 304 e non inserisce nulla', () async {
    final feed = await addFeed('/rss');
    await svc.fetchFeed(feed);
    final saved = (await db.getAllFeeds()).single;

    expect(await svc.fetchFeed(saved), 0);
    expect(requests.last.headers.value('if-none-match'), etag);
    expect(requests.last.response.statusCode, 304);
    expect((await db.watchArticlesByFeed(feed.id).first).length, 2);
  });

  test('Atom: content usato come testo pieno, summary come estratto', () async {
    final feed = await addFeed('/atom');
    expect(await svc.fetchFeed(feed), 1);
    final a = (await db.watchArticlesByFeed(feed.id).first).single;
    expect(a.author, 'Anna');
    expect(a.description, 'Riassunto breve.');
    expect(a.content, contains('Contenuto completo'));
  });
}
