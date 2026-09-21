import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import '../models/tables.dart';
import '../services/duplicate_detector.dart';

part 'database.g.dart';

@DriftDatabase(tables: [FeedSources, Articles])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// Per i test: usa un executor arbitrario (es. database in memoria).
  AppDatabase.forTesting(super.e);

  /// Giorni di conservazione degli articoli non preferiti.
  static const retentionDays = 30;

  /// Finestra in cui cercare duplicati di un articolo appena arrivato.
  static const _dedupeWindow = Duration(days: 3);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createSearchIndex();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(feedSources, feedSources.language);
      }
      if (from < 3) {
        await m.addColumn(feedSources, feedSources.etag);
        await m.addColumn(feedSources, feedSources.lastModified);
      }
      if (from < 4) {
        await m.addColumn(articles, articles.duplicateOf);
        await _createSearchIndex();
        await customStatement("INSERT INTO articles_fts(articles_fts) VALUES('rebuild')");
      }
      if (from < 5) {
        await m.addColumn(feedSources, feedSources.notify);
      }
    },
  );

  /// Indice full-text FTS5 a contenuto esterno: nessuna duplicazione dei testi,
  /// i trigger lo tengono allineato con la tabella articles.
  Future<void> _createSearchIndex() async {
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS articles_fts USING fts5(
        title, description, content,
        content='articles', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2'
      )''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS articles_fts_ai AFTER INSERT ON articles BEGIN
        INSERT INTO articles_fts(rowid, title, description, content)
        VALUES (new.id, new.title, new.description, new.content);
      END''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS articles_fts_ad AFTER DELETE ON articles BEGIN
        INSERT INTO articles_fts(articles_fts, rowid, title, description, content)
        VALUES ('delete', old.id, old.title, old.description, old.content);
      END''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS articles_fts_au
      AFTER UPDATE OF title, description, content ON articles BEGIN
        INSERT INTO articles_fts(articles_fts, rowid, title, description, content)
        VALUES ('delete', old.id, old.title, old.description, old.content);
        INSERT INTO articles_fts(rowid, title, description, content)
        VALUES (new.id, new.title, new.description, new.content);
      END''');
  }

  // ── Feed Sources ──────────────────────────────────────────────────────────

  Future<List<FeedSource>> getAllFeeds() =>
      (select(feedSources)..orderBy([(t) => OrderingTerm.asc(t.title)])).get();

  Stream<List<FeedSource>> watchAllFeeds() =>
      (select(feedSources)..orderBy([(t) => OrderingTerm.asc(t.title)])).watch();

  Future<int> insertFeed(FeedSourcesCompanion feed) =>
      into(feedSources).insert(feed);

  /// Inserisce i feed il cui URL non è già presente. Ritorna quanti ne ha aggiunti.
  Future<int> insertFeedsSkippingExisting(List<FeedSourcesCompanion> feeds) async {
    final known = (await getAllFeeds()).map((f) => f.url).toSet();
    var added = 0;
    for (final feed in feeds) {
      if (!known.add(feed.url.value)) continue;
      await into(feedSources).insert(feed);
      added++;
    }
    return added;
  }

  Future<bool> updateFeed(FeedSource feed) =>
      update(feedSources).replace(feed);

  Future<int> deleteFeed(int id) async {
    await (delete(articles)..where((t) => t.feedId.equals(id))).go();
    return (delete(feedSources)..where((t) => t.id.equals(id))).go();
  }

  // ── Articles ──────────────────────────────────────────────────────────────

  Stream<List<Article>> watchArticlesByFeed(int feedId) => (select(articles)
        ..where((t) => t.feedId.equals(feedId))
        ..orderBy([(t) => OrderingTerm.desc(t.publishedAt)]))
      .watch();

  Stream<List<Article>> watchAllArticles({bool onlyUnread = false}) {
    final query = select(articles)
      ..where((t) => t.duplicateOf.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.publishedAt)]);
    if (onlyUnread) query.where((t) => t.isRead.equals(false));
    return query.watch();
  }

  Stream<List<Article>> watchFavorites() => (select(articles)
        ..where((t) => t.isFavorite.equals(true))
        ..orderBy([(t) => OrderingTerm.desc(t.publishedAt)]))
      .watch();

  Future<Article?> getArticleById(int id) =>
      (select(articles)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Inserisce in un'unica transazione gli articoli non ancora presenti per
  /// il feed, marcando come duplicati quelli già arrivati da altre fonti.
  /// Salta gli articoli più vecchi del periodo di conservazione, altrimenti
  /// verrebbero reinseriti a ogni refresh e poi eliminati. Ritorna quanti
  /// articoli nuovi ha inserito.
  Future<int> insertNewArticles(int feedId, List<ArticlesCompanion> items) {
    return transaction(() async {
      final guidRows = await (selectOnly(articles)
            ..addColumns([articles.guid])
            ..where(articles.feedId.equals(feedId)))
          .get();
      final existing = guidRows.map((r) => r.read(articles.guid)).toSet();

      final now = DateTime.now();
      final retentionCutoff = now.subtract(const Duration(days: retentionDays));
      final recent = await (select(articles)
            ..where((t) =>
                t.fetchedAt.isBiggerOrEqualValue(now.subtract(_dedupeWindow)) &
                t.duplicateOf.isNull()))
          .get();
      final known = [
        for (final a in recent)
          KnownArticle(id: a.id, feedId: a.feedId, url: a.url, title: a.title),
      ];

      var added = 0;
      for (final item in items) {
        if (!existing.add(item.guid.value)) continue;
        final published = item.publishedAt.value;
        if (published != null && published.isBefore(retentionCutoff)) continue;

        final originalId = DuplicateDetector.findOriginal(
          feedId: feedId,
          url: item.url.value,
          title: item.title.value,
          known: known,
        );
        final id = await into(articles)
            .insert(item.copyWith(duplicateOf: Value(originalId)));
        if (originalId == null) {
          known.add(KnownArticle(
            id: id, feedId: feedId, url: item.url.value, title: item.title.value,
          ));
        }
        added++;
      }
      return added;
    });
  }

  /// Ricerca full-text (titolo, estratto e testo pieno), più rilevanti prima.
  /// Ogni parola è cercata come prefisso; i duplicati sono esclusi.
  Future<List<Article>> searchArticles(String input, {int limit = 100}) async {
    final query = ftsQuery(input);
    if (query == null) return [];
    final rows = await customSelect(
      'SELECT a.* FROM articles a '
      'JOIN articles_fts ON articles_fts.rowid = a.id '
      'WHERE articles_fts MATCH ?1 AND a.duplicate_of IS NULL '
      'ORDER BY bm25(articles_fts, 10.0, 3.0, 1.0) LIMIT ?2',
      variables: [Variable.withString(query), Variable.withInt(limit)],
      readsFrom: {articles},
    ).get();
    return rows.map((r) => articles.map(r.data)).toList();
  }

  /// Trasforma il testo digitato in una query FTS5 sicura: ogni parola tra
  /// virgolette (niente operatori) e con `*` per la ricerca per prefisso.
  static String? ftsQuery(String input) {
    final words = input
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((w) => w.isNotEmpty);
    if (words.isEmpty) return null;
    return words.map((w) => '"$w"*').join(' ');
  }

  Future<void> markAsRead(int id) => (update(articles)
        ..where((t) => t.id.equals(id)))
      .write(const ArticlesCompanion(isRead: Value(true)));

  Future<void> toggleFavorite(int id, bool value) => (update(articles)
        ..where((t) => t.id.equals(id)))
      .write(ArticlesCompanion(isFavorite: Value(value)));

  Future<void> saveAiSummary(int id, String summary) => (update(articles)
        ..where((t) => t.id.equals(id)))
      .write(ArticlesCompanion(aiSummary: Value(summary)));

  Future<void> saveArticleContent(int id, String content) =>
      (update(articles)..where((t) => t.id.equals(id)))
          .write(ArticlesCompanion(content: Value(content)));

  /// Id più alto tra gli articoli presenti (0 se non ce ne sono). Gli id sono
  /// AUTOINCREMENT, quindi tutto ciò che ha un id maggiore è arrivato dopo.
  Future<int> getMaxArticleId() async {
    final maxId = articles.id.max();
    final row = await (selectOnly(articles)..addColumns([maxId])).getSingle();
    return row.read(maxId) ?? 0;
  }

  /// Articoli non duplicati arrivati dopo [afterId] dai feed indicati.
  Future<List<Article>> getArticlesAfterId(int afterId, Set<int> feedIds) =>
      (select(articles)
            ..where((t) =>
                t.id.isBiggerThanValue(afterId) &
                t.feedId.isIn(feedIds) &
                t.duplicateOf.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.publishedAt)]))
          .get();

  Future<int> getUnreadCount(int feedId) async {
    final count = articles.id.count();
    final query = selectOnly(articles)
      ..addColumns([count])
      ..where(articles.feedId.equals(feedId) & articles.isRead.equals(false));
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  Future<List<Article>> getArticlesForPlayback({int? feedId}) {
    final query = select(articles)
      ..orderBy([(t) => OrderingTerm.desc(t.publishedAt)]);
    if (feedId != null) query.where((t) => t.feedId.equals(feedId));
    return query.get();
  }

  /// Elimina gli articoli non preferiti più vecchi di [keepDays] giorni.
  /// Per quelli senza data di pubblicazione conta la data di download.
  Future<int> pruneOldArticles({int keepDays = retentionDays}) {
    final cutoff = DateTime.now().subtract(Duration(days: keepDays));
    return (delete(articles)
          ..where((t) =>
              t.isFavorite.equals(false) &
              (t.publishedAt.isSmallerThanValue(cutoff) |
                  (t.publishedAt.isNull() & t.fetchedAt.isSmallerThanValue(cutoff)))))
        .go();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    // WAL + busy_timeout: l'app e il task in background (altro isolate)
    // possono aprire lo stesso file senza "database is locked".
    return driftDatabase(
      name: 'rss_reader',
      native: DriftNativeOptions(setup: (db) {
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA busy_timeout=5000');
      }),
    );
  });
}
