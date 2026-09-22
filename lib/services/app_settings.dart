import 'package:shared_preferences/shared_preferences.dart';

/// Impostazioni dell'utente per l'aggiornamento in background e per Gemma.
class AppSettings {
  static const _kEnabled = 'bg_refresh_enabled';
  static const _kHours = 'bg_refresh_hours';
  static const _kGemmaBackend = 'gemma_backend';
  static const _kGemmaLoadAttempt = 'gemma_load_attempt_pending';

  /// Intervalli proposti. WorkManager non scende sotto i 15 minuti; per non
  /// consumare batteria si parte da 1 ora.
  static const intervalOptionsHours = [1, 3, 6, 12];
  static const defaultIntervalHours = 3;

  static Future<bool> backgroundRefreshEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? false;

  static Future<int> backgroundIntervalHours() async {
    final v = (await SharedPreferences.getInstance()).getInt(_kHours);
    return intervalOptionsHours.contains(v) ? v! : defaultIntervalHours;
  }

  static Future<void> save({required bool enabled, required int hours}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, enabled);
    await prefs.setInt(_kHours, hours);
  }

  // ── Gemma: backend preferito ────────────────────────────────────────────

  /// 'cpu' o 'gpu'. Il default è 'cpu': la GPU va scelta esplicitamente.
  static Future<String> gemmaBackend() async =>
      (await SharedPreferences.getInstance()).getString(_kGemmaBackend) ?? 'cpu';

  static Future<void> saveGemmaBackend(String backend) async =>
      (await SharedPreferences.getInstance()).setString(_kGemmaBackend, backend);

  // ── Gemma: protezione dai crash nativi ──────────────────────────────────
  //
  // Un crash nativo (es. il delegate GPU) termina il processo senza lasciare
  // a Dart la possibilità di intercettarlo: nessun try/catch può vederlo.
  // Il trucco è marcare "sto per tentare il caricamento con X" PRIMA della
  // chiamata nativa rischiosa e cancellare il segno subito dopo, che la
  // chiamata sia riuscita o abbia lanciato un'eccezione normale. Se al
  // prossimo avvio il segno è ancora lì, l'ultimo tentativo non è arrivato
  // a un `finally`: quasi certamente un crash. SharedPreferences non è una
  // scrittura sincrona sul disco, quindi la protezione è "il più delle
  // volte", non una garanzia assoluta.

  static Future<void> markGemmaLoadAttempt(String backend) async =>
      (await SharedPreferences.getInstance()).setString(_kGemmaLoadAttempt, backend);

  static Future<void> clearGemmaLoadAttempt() async =>
      (await SharedPreferences.getInstance()).remove(_kGemmaLoadAttempt);

  /// Legge il segno lasciato da un tentativo precedente e lo cancella in un
  /// solo passaggio, così viene interpretato una volta sola.
  static Future<String?> consumeGemmaLoadAttempt() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getString(_kGemmaLoadAttempt);
    if (pending != null) await prefs.remove(_kGemmaLoadAttempt);
    return pending;
  }
}
