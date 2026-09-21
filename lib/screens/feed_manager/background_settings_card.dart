import 'package:flutter/material.dart';
import '../../services/app_settings.dart';
import '../../services/background_refresh.dart';
import '../../services/notification_service.dart';
import '../../theme/app_theme.dart';

/// Interruttore e intervallo dell'aggiornamento periodico in background.
/// Le notifiche si scelgono per singola fonte (campanella nella lista).
class BackgroundSettingsCard extends StatefulWidget {
  const BackgroundSettingsCard({super.key});

  @override
  State<BackgroundSettingsCard> createState() => _BackgroundSettingsCardState();
}

class _BackgroundSettingsCardState extends State<BackgroundSettingsCard> {
  bool _enabled = false;
  int _hours = AppSettings.defaultIntervalHours;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await AppSettings.backgroundRefreshEnabled();
    final hours = await AppSettings.backgroundIntervalHours();
    if (mounted) setState(() { _enabled = enabled; _hours = hours; _loaded = true; });
  }

  Future<void> _update({bool? enabled, int? hours}) async {
    final newEnabled = enabled ?? _enabled;
    final newHours = hours ?? _hours;
    try {
      await BackgroundRefresh.apply(enabled: newEnabled, hours: newHours);
      await AppSettings.save(enabled: newEnabled, hours: newHours);
      if (mounted) setState(() { _enabled = newEnabled; _hours = newHours; });

      if (enabled == true) {
        final granted = await NotificationService.requestPermission();
        if (!granted && mounted) {
          _snack('Notifiche non consentite: le fonti verranno aggiornate senza avvisi.');
        }
      }
    } catch (e) {
      if (mounted) _snack('Impossibile pianificare l\'aggiornamento: $e', error: true);
    }
  }

  void _snack(String message, {bool error = false}) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: error ? AppTheme.error : null,
      ));

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return SwitchListTile(
      value: _enabled,
      onChanged: _loaded ? (v) => _update(enabled: v) : null,
      activeThumbColor: AppTheme.accent,
      title: Text('Aggiorna in background', style: tt.titleMedium),
      subtitle: _enabled
          ? Row(
              children: [
                Text('Ogni', style: tt.bodySmall),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _hours,
                  isDense: true,
                  dropdownColor: AppTheme.surfaceHigh,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final h in AppSettings.intervalOptionsHours)
                      DropdownMenuItem(value: h, child: Text(h == 1 ? '1 ora' : '$h ore')),
                  ],
                  onChanged: (h) => h == null ? null : _update(hours: h),
                ),
              ],
            )
          : Text(
              'Scarica le nuove notizie anche ad app chiusa. '
              'Attiva la campanella sulle fonti da cui vuoi ricevere avvisi.',
              style: tt.bodySmall,
            ),
    );
  }
}
