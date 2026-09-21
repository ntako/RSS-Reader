import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rss_reader/providers/app_providers.dart';
import 'package:rss_reader/services/gemma_service.dart';

/// Articolo lungo: più blocchi da [GemmaService.chunkChars] caratteri.
String longArticle(int paragraphs) => List.generate(
      paragraphs,
      (i) => 'Paragrafo $i. ${'Testo di prova dell\'articolo. ' * 30}',
    ).join('\n\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('summarize (con un modello finto)', () {
    test('articolo breve: una sola chiamata, con titolo e testo nel prompt', () async {
      final prompts = <String>[];
      final svc = GemmaService.withRunner((p) async {
        prompts.add(p);
        return '  Riassunto breve.  ';
      });

      expect(await svc.summarize('Il titolo', 'Un testo corto.'), 'Riassunto breve.');
      expect(prompts.length, 1);
      expect(prompts.single, contains('Il titolo'));
      expect(prompts.single, contains('Un testo corto.'));
    });

    test('articolo lungo: un riassunto per blocco e uno finale sui parziali', () async {
      final prompts = <String>[];
      var n = 0;
      final svc = GemmaService.withRunner((p) async {
        prompts.add(p);
        return 'parziale-${++n}';
      });

      final result = await svc.summarize('T', longArticle(8));

      expect(prompts.length, greaterThan(2));
      expect(result, 'parziale-${prompts.length}'); // l'ultima chiamata è la finale
      final finalPrompt = prompts.last;
      expect(finalPrompt, contains('parziale-1'));
      expect(finalPrompt, contains('parziale-${prompts.length - 1}'));
      expect(prompts.first, contains('Parte 1'));
    });

    test('non elabora più di 6 blocchi', () async {
      var calls = 0;
      final svc = GemmaService.withRunner((p) async => 'x${++calls}');
      await svc.summarize('T', longArticle(60));
      expect(calls, 6 + 1); // 6 blocchi + il riassunto finale
    });

    test('un blocco che fallisce: errore che dice quale parte e in che fase', () async {
      var calls = 0;
      final svc = GemmaService.withRunner((p) async {
        if (++calls == 2) throw const GemmaException('generazione', 'memoria esaurita');
        return 'ok';
      });

      await expectLater(
        svc.summarize('T', longArticle(8)),
        throwsA(isA<GemmaException>()
            .having((e) => e.part, 'part', startsWith('parte 2 di'))
            .having((e) => '$e', 'messaggio', allOf(contains('parte 2'), contains('generazione'), contains('memoria esaurita')))),
      );
    });

    test('un errore qualsiasi del modello diventa GemmaException, non null', () async {
      final svc = GemmaService.withRunner((p) async => throw StateError('crash nativo'));
      await expectLater(
        svc.summarize('T', 'Testo.'),
        throwsA(isA<GemmaException>().having((e) => '$e', 'messaggio', contains('crash nativo'))),
      );
    });

    test('risposta vuota: errore esplicito invece di un riassunto vuoto', () async {
      final svc = GemmaService.withRunner((p) async => '   ');
      await expectLater(
        svc.summarize('T', 'Testo.'),
        throwsA(isA<GemmaException>().having((e) => '$e', 'messaggio', contains('vuota'))),
      );
    });

    test('modello non caricato o testo vuoto: errore leggibile', () async {
      await expectLater(
        GemmaService().summarize('T', 'Testo.'),
        throwsA(isA<GemmaException>().having((e) => '$e', 'messaggio', contains('non caricato'))),
      );
      await expectLater(
        GemmaService.withRunner((p) async => 'x').summarize('T', '  \n '),
        throwsA(isA<GemmaException>().having((e) => '$e', 'messaggio', contains('senza testo'))),
      );
    });
  });

  group('caricamento all\'avvio', () {
    late Directory docs;

    setUp(() {
      docs = Directory.systemTemp.createTempSync('gemma_test_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => docs.path,
      );
    });
    tearDown(() => docs.deleteSync(recursive: true));

    test('nessun modello installato: "non configurato"', () async {
      final notifier = GemmaModelNotifier(GemmaService());
      await notifier.init();
      expect(notifier.state.$1, GemmaModelState.notDownloaded);
    });

    test('modello presente ma che non si carica: stato di errore con il motivo', () async {
      File('${docs.path}/gemma_model.task').writeAsStringSync('non è un modello');
      final notifier = GemmaModelNotifier(GemmaService());
      await notifier.init(); // nei test il plugin nativo non esiste: il caricamento fallisce

      expect(notifier.state.$1, GemmaModelState.error);
      expect(notifier.lastError, isNotEmpty);
    });
  });
}
