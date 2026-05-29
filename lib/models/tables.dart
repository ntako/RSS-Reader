import 'package:drift/drift.dart';

// Tabella fonti RSS
class FeedSources extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 200)();
  TextColumn get url => text().withLength(min: 1, max: 500)();
  TextColumn get description => text().nullable()();
  TextColumn get iconUrl => text().nullable()();
  TextColumn get category => text().withDefault(const Constant('Generale'))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get language => text().nullable()();
  DateTimeColumn get lastFetched => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

// Tabella articoli
class Articles extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get feedId => integer().references(FeedSources, #id)();
  TextColumn get guid => text().withLength(min: 1, max: 500)();
  TextColumn get title => text().withLength(min: 1, max: 500)();
  TextColumn get url => text().withLength(min: 1, max: 500)();
  TextColumn get author => text().nullable()();
  TextColumn get description => text().nullable()();   // estratto HTML
  TextColumn get content => text().nullable()();       // testo pieno pulito
  TextColumn get imageUrl => text().nullable()();
  TextColumn get aiSummary => text().nullable()();     // riassunto Gemma
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  DateTimeColumn get publishedAt => dateTime().nullable()();
  DateTimeColumn get fetchedAt => dateTime().withDefault(currentDateAndTime)();
}
