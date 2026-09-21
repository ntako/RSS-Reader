import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Un articolo nuovo da segnalare.
class NewArticleNotice {
  final String feedTitle;
  final String articleTitle;
  const NewArticleNotice({required this.feedTitle, required this.articleTitle});
}

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'new_articles';
  static const _notificationId = 1;
  static const _maxLines = 4;

  static Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _android?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      'Nuovi articoli',
      description: 'Notifiche per i nuovi articoli delle fonti seguite',
      importance: Importance.defaultImportance,
    ));
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Chiede il permesso (Android 13+). Ritorna true se le notifiche sono attive.
  static Future<bool> requestPermission() async =>
      await _android?.requestNotificationsPermission() ?? false;

  /// Titolo e testo del riepilogo: un solo articolo → il suo titolo;
  /// più articoli → conteggio e primi titoli.
  static ({String title, String body}) summarize(List<NewArticleNotice> items) {
    if (items.length == 1) {
      return (title: items.first.articleTitle, body: items.first.feedTitle);
    }
    final lines = items.take(_maxLines).map((n) => '${n.feedTitle}: ${n.articleTitle}');
    final more = items.length - _maxLines;
    return (
      title: '${items.length} nuovi articoli',
      body: [...lines, if (more > 0) 'e altri $more…'].join('\n'),
    );
  }

  /// Mostra un'unica notifica di riepilogo: con id fisso sostituisce la
  /// precedente invece di accumularne una per ogni refresh.
  static Future<void> showNewArticles(List<NewArticleNotice> items) async {
    if (items.isEmpty) return;
    final s = summarize(items);
    await _plugin.show(
      id: _notificationId,
      title: s.title,
      body: s.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Nuovi articoli',
          styleInformation: BigTextStyleInformation(s.body),
        ),
      ),
    );
  }
}
