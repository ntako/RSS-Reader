import 'dart:ffi';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rss_reader/database/database.dart';
import 'package:rss_reader/services/background_refresh.dart';
import 'package:rss_reader/services/notification_service.dart';
import 'package:rss_reader/services/rss_service.dart';
import 'package:sqlite3/open.dart';

String rss(List<(String guid, String title)> items) => '''<?xml version="1.0"?>
<rss version="2.0"><channel><title>T</title>
${items.map((i) => '<item><title>${i.$2}</title><link>https://t.it/${i.$1}</link><guid>${i.$1}</guid>'
    '<pubDate>${HttpDate.format(DateTime.now())}</pubDate><description>x</description></item>').join()}
</channel></rss>''';

void main() {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  }

  late HttpServer server;
  late AppDatabase db;
  var body = '';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) {
      req.response.headers.contentType = ContentType('application', 'rss+xml', charset: 'utf-8');
      req.response.write(body);
      req.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await db.close();
  });

  Future<void> addFeed(String name, String path, {bool notify = true}) => db.insertFeed(
        FeedSourcesCompanion.insert(
          title: name, url: 'http://127.0.0.1:${server.port}$path', notify: Value(notify)),
      );

  test('notifica solo gli articoli arrivati dopo il primo caricamento', () async {
    await addFeed('Feed A', '/a');
    body = rss([('1', 'Vecchio uno'), ('2', 'Vecchio due')]);

    // Primo refresh: il feed non è mai stato aggiornato → nessuna notifica.
    expect(await BackgroundRefresh.refreshAndCollect(db), isEmpty);

    body = rss([('1', 'Vecchio uno'), ('2', 'Vecchio due'), ('3', 'Notizia nuova')]);
    final notices = await BackgroundRefresh.refreshAndCollect(db);
    expect(notices.map((n) => n.articleTitle), ['Notizia nuova']);
    expect(notices.single.feedTitle, 'Feed A');

    // Nessuna novità → nessuna notifica.
    expect(await BackgroundRefresh.refreshAndCollect(db), isEmpty);
  });

  test('i feed con notify=false non generano notifiche', () async {
    await addFeed('Muto', '/a', notify: false);
    body = rss([('1', 'Uno')]);
    await BackgroundRefresh.refreshAndCollect(db);
    body = rss([('1', 'Uno'), ('2', 'Due')]);
    expect(await BackgroundRefresh.refreshAndCollect(db), isEmpty);
    expect((await db.watchAllArticles().first).length, 2); // ma vengono salvati
  });

  test('un articolo già arrivato da un\'altra fonte non viene notificato', () async {
    await addFeed('Feed A', '/a');
    body = rss([('1', 'Iniziale')]);
    await BackgroundRefresh.refreshAndCollect(db); // A ora è "già aggiornato"

    // Un secondo feed (non monitorato) riceve per primo la notizia 9.
    await addFeed('Altro', '/b', notify: false);
    final altro = (await db.getAllFeeds()).firstWhere((f) => f.title == 'Altro');
    body = rss([('1', 'Iniziale'), ('9', 'Stessa notizia')]);
    await RssService(db).fetchFeed(altro);

    // Ora A la vede: stesso URL → duplicato, quindi niente notifica.
    expect(await BackgroundRefresh.refreshAndCollect(db), isEmpty);
    final feedA = (await db.getAllFeeds()).firstWhere((f) => f.title == 'Feed A');
    final nine = (await db.watchArticlesByFeed(feedA.id).first).firstWhere((a) => a.guid == '9');
    expect(nine.duplicateOf, isNotNull);
  });

  group('riepilogo notifica', () {
    test('un articolo: titolo dell\'articolo, testo con la fonte', () {
      final s = NotificationService.summarize(
          [const NewArticleNotice(feedTitle: 'ANSA', articleTitle: 'Titolo')]);
      expect((s.title, s.body), ('Titolo', 'ANSA'));
    });

    test('molti articoli: conteggio, righe limitate e "altri"', () {
      final s = NotificationService.summarize([
        for (var i = 1; i <= 7; i++)
          NewArticleNotice(feedTitle: 'F', articleTitle: 'T$i'),
      ]);
      expect(s.title, '7 nuovi articoli');
      expect(s.body.split('\n').length, 5);
      expect(s.body, endsWith('e altri 3…'));
    });
  });
}
