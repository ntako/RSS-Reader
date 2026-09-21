import 'package:workmanager/workmanager.dart';

import '../database/database.dart';
import 'notification_service.dart';
import 'rss_service.dart';

const _taskName = 'refresh_feeds';
const _uniqueName = 'rss_refresh_periodic';

/// Punto d'ingresso del task periodico; gira in un isolate separato, senza
/// UI né Riverpod, quindi apre da sé il database e chiude tutto a fine lavoro.
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final db = AppDatabase();
    try {
      final notices = await BackgroundRefresh.refreshAndCollect(db);
      if (notices.isNotEmpty) {
        await NotificationService.init();
        await NotificationService.showNewArticles(notices);
      }
      return true;
    } catch (_) {
      return false; // WorkManager riprova con backoff
    } finally {
      await db.close();
    }
  });
}

class BackgroundRefresh {
  static Future<void> init() => Workmanager().initialize(backgroundCallbackDispatcher);

  /// Attiva o disattiva l'aggiornamento periodico.
  static Future<void> apply({required bool enabled, required int hours}) async {
    if (!enabled) {
      await Workmanager().cancelByUniqueName(_uniqueName);
      return;
    }
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      _taskName,
      frequency: Duration(hours: hours),
      // update: un cambio di intervallo sostituisce quello precedente.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
    );
  }

  /// Aggiorna tutti i feed e ritorna gli articoli nuovi delle fonti con le
  /// notifiche attive. I feed mai aggiornati prima (appena aggiunti) sono
  /// esclusi: il loro primo caricamento non è una "novità".
  static Future<List<NewArticleNotice>> refreshAndCollect(AppDatabase db) async {
    final feeds = await db.getAllFeeds();
    final watched = {
      for (final f in feeds)
        if (f.notify && f.isActive && f.lastFetched != null) f.id: f.title,
    };
    final lastKnownId = await db.getMaxArticleId();

    await RssService(db).fetchAllFeeds();

    if (watched.isEmpty) return [];
    final fresh = await db.getArticlesAfterId(lastKnownId, watched.keys.toSet());
    return [
      for (final a in fresh)
        NewArticleNotice(feedTitle: watched[a.feedId]!, articleTitle: a.title),
    ];
  }
}
