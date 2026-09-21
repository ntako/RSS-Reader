import 'package:shared_preferences/shared_preferences.dart';

/// Impostazioni dell'utente per l'aggiornamento in background.
class AppSettings {
  static const _kEnabled = 'bg_refresh_enabled';
  static const _kHours = 'bg_refresh_hours';

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
}
