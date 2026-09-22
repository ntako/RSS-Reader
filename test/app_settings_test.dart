import 'package:flutter_test/flutter_test.dart';
import 'package:rss_reader/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('backend di Gemma', () {
    test('il default è la CPU', () async {
      expect(await AppSettings.gemmaBackend(), 'cpu');
    });

    test('si salva e si rilegge', () async {
      await AppSettings.saveGemmaBackend('gpu');
      expect(await AppSettings.gemmaBackend(), 'gpu');

      await AppSettings.saveGemmaBackend('cpu');
      expect(await AppSettings.gemmaBackend(), 'cpu');
    });
  });

  group('segno di un caricamento in corso (protezione dai crash)', () {
    test('senza nessun tentativo marcato, consume ritorna null', () async {
      expect(await AppSettings.consumeGemmaLoadAttempt(), isNull);
    });

    test('un tentativo marcato viene letto una volta sola', () async {
      await AppSettings.markGemmaLoadAttempt('gpu');

      expect(await AppSettings.consumeGemmaLoadAttempt(), 'gpu');
      expect(await AppSettings.consumeGemmaLoadAttempt(), isNull,
          reason: 'il primo consume deve averlo già cancellato');
    });

    test('clearGemmaLoadAttempt cancella il segno senza doverlo leggere', () async {
      await AppSettings.markGemmaLoadAttempt('cpu');
      await AppSettings.clearGemmaLoadAttempt();
      expect(await AppSettings.consumeGemmaLoadAttempt(), isNull);
    });

    test('marcare di nuovo sovrascrive il tentativo precedente', () async {
      await AppSettings.markGemmaLoadAttempt('cpu');
      await AppSettings.markGemmaLoadAttempt('gpu');
      expect(await AppSettings.consumeGemmaLoadAttempt(), 'gpu');
    });
  });
}
