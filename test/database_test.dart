import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:rss_reader/database/database.dart';
import 'package:rss_reader/services/duplicate_detector.dart';

ArticlesCompanion art(int feed, String guid, String title, String url,
        {String? description, DateTime? published}) =>
    ArticlesCompanion.insert(
      feedId: feed, guid: guid, title: title, url: url,
      description: Value(description),
      publishedAt: Value(published ?? DateTime.now()),
    );

void main() {
  // Su Linux senza libsqlite3-dev manca il link `libsqlite3.so`: usa la .so.0.
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  }

  late AppDatabase db;
  late int feedA, feedB;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    feedA = await db.insertFeed(FeedSourcesCompanion.insert(title: 'A', url: 'https://a.it/rss'));
    feedB = await db.insertFeed(FeedSourcesCompanion.insert(title: 'B', url: 'https://b.it/rss'));
  });
  tearDown(() => db.close());

  group('insertNewArticles', () {
    test('inserisce i nuovi e ignora i guid già presenti', () async {
      final items = [
        art(feedA, 'g1', 'Primo articolo di prova', 'https://a.it/1'),
        art(feedA, 'g2', 'Secondo articolo di prova', 'https://a.it/2'),
      ];
      expect(await db.insertNewArticles(feedA, items), 2);
      expect(await db.insertNewArticles(feedA, items), 0);
    });

    test('salta gli articoli più vecchi della retention', () async {
      final old = DateTime.now().subtract(const Duration(days: 60));
      expect(
        await db.insertNewArticles(feedA, [art(feedA, 'old', 'Vecchio', 'https://a.it/old', published: old)]),
        0,
      );
    });

    test('stesso URL su due feed: il secondo è duplicato e nascosto in "tutti"', () async {
      await db.insertNewArticles(feedA, [art(feedA, 'x', 'Titolo uno', 'https://www.a.it/n/1/?utm_source=tw')]);
      await db.insertNewArticles(feedB, [art(feedB, 'y', 'Altro titolo', 'https://a.it/n/1')]);
      final all = await db.watchAllArticles().first;
      expect(all.length, 1);
      expect((await db.watchArticlesByFeed(feedB).first).single.duplicateOf, all.single.id);
    });

    test('titoli simili da feed diversi sono duplicati, dallo stesso feed no', () async {
      await db.insertNewArticles(feedA, [
        art(feedA, '1', 'Terremoto in Turchia: oltre cento morti, soccorsi al lavoro', 'https://a.it/1'),
        art(feedA, '2', 'Terremoto in Turchia: oltre cento morti, soccorsi al lavoro ora', 'https://a.it/2'),
      ]);
      expect((await db.watchAllArticles().first).length, 2);

      await db.insertNewArticles(feedB, [
        art(feedB, '3', 'Turchia, terremoto: oltre cento morti e soccorsi al lavoro', 'https://b.it/9'),
      ]);
      expect((await db.watchAllArticles().first).length, 2);
    });

    test('titoli diversi non sono duplicati', () async {
      await db.insertNewArticles(feedA, [art(feedA, '1', 'Elezioni regionali: affluenza in calo', 'https://a.it/1')]);
      await db.insertNewArticles(feedB, [art(feedB, '2', 'Borsa di Milano chiude in rialzo', 'https://b.it/2')]);
      expect((await db.watchAllArticles().first).length, 2);
    });
  });

  group('ricerca full-text', () {
    setUp(() async {
      await db.insertNewArticles(feedA, [
        art(feedA, '1', 'Il governo approva la manovra', 'https://a.it/1', description: 'Legge di bilancio con novità per i pensionati'),
        art(feedA, '2', 'Calcio: la Juventus vince', 'https://a.it/2', description: 'Partita decisa nel finale'),
      ]);
    });

    test('trova per titolo, per prefisso e ignora accenti', () async {
      expect((await db.searchArticles('manovra')).length, 1);
      expect((await db.searchArticles('manov')).length, 1);
      expect((await db.searchArticles('novita')).length, 1); // "novità"
    });

    test('trova nel testo pieno dopo saveArticleContent', () async {
      final id = (await db.searchArticles('juventus')).single.id;
      expect(await db.searchArticles('rigore'), isEmpty);
      await db.saveArticleContent(id, 'Decide un rigore al novantesimo.');
      expect((await db.searchArticles('rigore')).single.id, id);
    });

    test('input con caratteri speciali FTS non lancia', () async {
      expect(await db.searchArticles('"AND OR * ( NEAR'), isEmpty);
      expect(await db.searchArticles('   '), isEmpty);
    });

    test('un articolo eliminato non compare più', () async {
      await db.pruneOldArticles(keepDays: -1); // taglia tutto
      expect(await db.searchArticles('manovra'), isEmpty);
    });
  });

  group('retention', () {
    test('elimina i vecchi non preferiti, anche senza publishedAt', () async {
      await db.insertNewArticles(feedA, [
        art(feedA, '1', 'Recente uno', 'https://a.it/1'),
        art(feedA, '2', 'Preferito due', 'https://a.it/2'),
      ]);
      final id = (await db.watchAllArticles().first).first.id;
      await db.toggleFavorite(id, true);
      expect(await db.pruneOldArticles(keepDays: -1), 1);
      expect((await db.watchFavorites().first).length, 1);
    });
  });

  test('ftsQuery e normalizeUrl', () {
    expect(AppDatabase.ftsQuery('caffè, "latte"'), '"caffè"* "latte"*');
    expect(AppDatabase.ftsQuery('***'), isNull);
    expect(DuplicateDetector.normalizeUrl('https://WWW.a.it/x/?utm_medium=z&id=3#top'), 'a.it/x?id=3');
  });

  test('migrazione v3 → v4 conserva i dati e indicizza gli articoli esistenti', () async {
    final old = AppDatabase.forTesting(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE feed_sources (
          id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, url TEXT NOT NULL,
          description TEXT, icon_url TEXT, category TEXT NOT NULL DEFAULT 'Generale',
          is_active INTEGER NOT NULL DEFAULT 1, language TEXT, last_fetched INTEGER,
          etag TEXT, last_modified TEXT, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')));
        CREATE TABLE articles (
          id INTEGER PRIMARY KEY AUTOINCREMENT, feed_id INTEGER NOT NULL, guid TEXT NOT NULL,
          title TEXT NOT NULL, url TEXT NOT NULL, author TEXT, description TEXT, content TEXT,
          image_url TEXT, ai_summary TEXT, is_read INTEGER NOT NULL DEFAULT 0,
          is_favorite INTEGER NOT NULL DEFAULT 0, published_at INTEGER,
          fetched_at INTEGER NOT NULL DEFAULT (strftime('%s','now')));
        INSERT INTO feed_sources (title, url) VALUES ('Vecchio feed', 'https://v.it/rss');
        INSERT INTO articles (feed_id, guid, title, url, description, published_at)
          VALUES (1, 'g', 'Articolo preesistente sulla manovra', 'https://v.it/1', 'testo', strftime('%s','now'));
        PRAGMA user_version = 3;
      ''');
    }));
    addTearDown(old.close);

    final found = await old.searchArticles('manovra');
    expect(found.single.title, 'Articolo preesistente sulla manovra');
    expect(found.single.duplicateOf, isNull);

    // Dopo la migrazione i nuovi inserimenti restano indicizzati dai trigger.
    await old.insertNewArticles(1, [art(1, 'n', 'Nuovo pezzo sul referendum', 'https://v.it/2')]);
    expect((await old.searchArticles('referendum')).length, 1);
  });

  test('migrazione v2 → v5 (app originale) conserva i dati e abilita tutte le funzioni nuove', () async {
    // Schema della prima versione dell'app: senza etag, lastModified, notify, duplicate_of.
    final old = AppDatabase.forTesting(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE feed_sources (
          id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, url TEXT NOT NULL,
          description TEXT, icon_url TEXT, category TEXT NOT NULL DEFAULT 'Generale',
          is_active INTEGER NOT NULL DEFAULT 1, language TEXT, last_fetched INTEGER,
          created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')));
        CREATE TABLE articles (
          id INTEGER PRIMARY KEY AUTOINCREMENT, feed_id INTEGER NOT NULL, guid TEXT NOT NULL,
          title TEXT NOT NULL, url TEXT NOT NULL, author TEXT, description TEXT, content TEXT,
          image_url TEXT, ai_summary TEXT, is_read INTEGER NOT NULL DEFAULT 0,
          is_favorite INTEGER NOT NULL DEFAULT 0, published_at INTEGER,
          fetched_at INTEGER NOT NULL DEFAULT (strftime('%s','now')));
        INSERT INTO feed_sources (title, url, category) VALUES ('Vecchio feed', 'https://v.it/rss', 'Politica');
        INSERT INTO articles (feed_id, guid, title, url, description, ai_summary, is_favorite, published_at)
          VALUES (1, 'g1', 'Vecchio articolo sulla manovra', 'https://v.it/1', 'testo', 'riassunto salvato', 1, strftime('%s','now'));
        PRAGMA user_version = 2;
      ''');
    }));
    addTearDown(old.close);

    // Dati preesistenti intatti, con i valori predefiniti delle colonne nuove.
    final feed = (await old.getAllFeeds()).single;
    expect((feed.title, feed.category), ('Vecchio feed', 'Politica'));
    expect(feed.notify, isFalse);
    expect(feed.etag, isNull);
    final article = (await old.watchAllArticles().first).single;
    expect((article.aiSummary, article.isFavorite), ('riassunto salvato', true));
    expect(article.duplicateOf, isNull);

    // Ricerca sugli articoli già presenti, e sui nuovi tramite i trigger.
    expect((await old.searchArticles('manovra')).single.id, article.id);
    await old.insertNewArticles(1, [art(1, 'n', 'Nuovo pezzo sul referendum', 'https://v.it/2')]);
    expect((await old.searchArticles('referendum')).length, 1);

    // Deduplica e aggiornamento condizionale funzionano sullo schema migrato.
    await old.insertNewArticles(1, [art(1, 'x', 'Altro titolo', 'https://v.it/1')]);
    expect((await old.getArticlesAfterId(0, {1})).length, 2); // l'URL doppio non è stato contato
    await old.updateFeed(feed.copyWith(etag: const Value('"e"'), notify: true));
    final updated = (await old.getAllFeeds()).single;
    expect((updated.etag, updated.notify), ('"e"', true));
  });
}
