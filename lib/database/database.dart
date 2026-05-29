import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import '../models/tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [FeedSources, Articles])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(feedSources, feedSources.language);
      }
    },
  );

  // ── Feed Sources ──────────────────────────────────────────────────────────

  Future<List<FeedSource>> getAllFeeds() =>
      (select(feedSources)..orderBy([(t) => OrderingTerm.asc(t.title)])).get();

  Stream<List<FeedSource>> watchAllFeeds() =>
      (select(feedSources)..orderBy([(t) => OrderingTerm.asc(t.title)])).watch();

  Future<int> insertFeed(FeedSourcesCompanion feed) =>
      into(feedSources).insert(feed);

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

  /// Inserisce un articolo solo se non esiste già (controlla feedId + guid).
  /// Ritorna true se è un nuovo articolo, false se era già presente.
  Future<bool> upsertArticle(ArticlesCompanion article) async {
    final exists = await (select(articles)
          ..where((t) =>
              t.feedId.equals(article.feedId.value) &
              t.guid.equals(article.guid.value)))
        .getSingleOrNull();
    if (exists != null) return false;
    await into(articles).insert(article);
    return true;
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

  // Elimina articoli più vecchi di N giorni
  Future<int> pruneOldArticles({int keepDays = 30}) {
    final cutoff = DateTime.now().subtract(Duration(days: keepDays));
    return (delete(articles)
          ..where((t) =>
              t.publishedAt.isSmallerThanValue(cutoff) &
              t.isFavorite.equals(false)))
        .go();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    return driftDatabase(name: 'rss_reader');
  });
}
