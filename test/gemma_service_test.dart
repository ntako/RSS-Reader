import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rss_reader/providers/app_providers.dart';
import 'package:rss_reader/services/app_settings.dart';
import 'package:rss_reader/services/gemma_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tar/tar.dart';

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
      SharedPreferences.setMockInitialValues({});
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

    group('protezione dai crash della GPU', () {
      test('un segno di tentativo GPU rimasto pendente (crash) disattiva la GPU', () async {
        // Simula quello che resta su disco se l'app è morta a metà di un
        // caricamento con la GPU: il segno di "sto per provare" non è mai
        // stato cancellato.
        SharedPreferences.setMockInitialValues({
          'gemma_backend': 'gpu',
          'gemma_load_attempt_pending': 'gpu',
        });

        final notifier = GemmaModelNotifier(GemmaService());
        await notifier.init();

        expect(notifier.backend, 'cpu', reason: 'per questo avvio, subito');
        expect(notifier.gpuDowngradedByCrash, isTrue);
        expect(await AppSettings.gemmaBackend(), 'cpu', reason: 'persistito, non solo in memoria');
      });

      test('un segno pendente per la CPU non attiva l\'avviso né cambia nulla', () async {
        SharedPreferences.setMockInitialValues({
          'gemma_backend': 'cpu',
          'gemma_load_attempt_pending': 'cpu',
        });

        final notifier = GemmaModelNotifier(GemmaService());
        await notifier.init();

        expect(notifier.backend, 'cpu');
        expect(notifier.gpuDowngradedByCrash, isFalse);
      });

      test('senza segni pendenti la preferenza salvata è rispettata', () async {
        SharedPreferences.setMockInitialValues({'gemma_backend': 'gpu'});

        final notifier = GemmaModelNotifier(GemmaService());
        await notifier.init();

        expect(notifier.backend, 'gpu');
        expect(notifier.gpuDowngradedByCrash, isFalse);
      });

      test('un caricamento che fallisce normalmente non lascia il segno acceso', () async {
        // Il caso opposto al crash: un'eccezione Dart normale (qui, plugin
        // nativo assente nei test) attraversa il `finally` di loadModel e
        // cancella il segno. Se questo non funzionasse, ogni errore normale
        // verrebbe scambiato per un crash al riavvio successivo.
        File('${docs.path}/gemma_model.task').writeAsStringSync('non è un modello');
        await expectLater(GemmaService().loadModel(backend: GemmaBackend.gpu), throwsA(anything));

        expect(await AppSettings.consumeGemmaLoadAttempt(), isNull);
      });
    });
  });

  group('generazione protetta da ripetizioni e testi senza fine', () {
    /// Token uno alla volta, come li emette il modello; conta quanti ne vengono letti.
    Stream<String> tokens(List<String> parts, void Function() onRead) async* {
      for (final t in parts) {
        onRead();
        yield t;
      }
    }

    test('una risposta normale passa intatta', () async {
      final out = await GemmaService.collectGuarded(
        tokens(['Il governo ', 'approva la manovra. ', 'Divergono i sindacati.'], () {}),
        maxChars: 700,
      );
      expect(out.cut, isFalse);
      expect(out.text, 'Il governo approva la manovra. Divergono i sindacati.');
    });

    test('il caso reale del telefono: "è è è è…" viene fermato e la frase monca tolta', () async {
      // Quasi parola per parola l'output visto su un Gemma 3 1B reale.
      final parts = [
        'Mario Adinolfi è stato arrestato per un reato di truffa e evasione fiscale. ',
        "L'inchiesta è è un'aggravazione della misura cautelare. ",
        "L'esito dell'indagine è un'esplosione di denaro che ",
        ...List.filled(500, 'è '),
      ];
      var read = 0;
      final out = await GemmaService.collectGuarded(tokens(parts, () => read++), maxChars: 700);

      expect(out.cut, isTrue);
      expect(read, lessThan(20), reason: 'deve smettere di leggere subito, non consumare 500 token');
      expect(out.text, endsWith('misura cautelare.'));
      expect(out.text, isNot(contains('è è è')));
      expect(out.text, startsWith('Mario Adinolfi è stato arrestato'));
    });

    test('un ciclo senza spazi ("èèèèèèèèèè") viene fermato', () async {
      var read = 0;
      final parts = ['Frase completa e sufficientemente lunga per essere tenuta. Poi ', ...List.filled(200, 'èè')];
      final out = await GemmaService.collectGuarded(tokens(parts, () => read++), maxChars: 700);
      expect(out.cut, isTrue);
      expect(read, lessThan(30));
      expect(out.text, 'Frase completa e sufficientemente lunga per essere tenuta.');
    });

    test('un testo che non finisce mai si ferma al tetto e chiude all\'ultima frase', () async {
      var read = 0;
      final parts = List.generate(400, (i) => 'Frase numero $i che continua. ');
      final out = await GemmaService.collectGuarded(tokens(parts, () => read++), maxChars: 200);

      expect(out.cut, isTrue);
      expect(read, lessThan(15));
      expect(out.text.length, lessThanOrEqualTo(260));
      expect(out.text, endsWith('.'));
    });

    test('cleanSummary: comprime le ripetizioni e non tocca il testo normale', () {
      expect(GemmaService.cleanSummary('Ha detto è è è è è è che va bene.', cut: false), 'Ha detto è che va bene.');
      expect(GemmaService.cleanSummary('molto molto bello e no no giusto', cut: false), 'molto molto bello e no no giusto');
      expect(GemmaService.cleanSummary('  Testo   con   spazi. ', cut: false), 'Testo con spazi.');
    });

    test('cleanSummary: se interrotta non taglia a metà di un riassunto troppo corto', () {
      expect(GemmaService.cleanSummary('Ok. e poi', cut: true), 'Ok. e poi', reason: 'meno di 40 caratteri: meglio tenerlo che svuotarlo');
    });
  });

  group('sostituzione del modello installato', () {
    late Directory docs;

    setUp(() {
      docs = Directory.systemTemp.createTempSync('gemma_replace_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => docs.path,
      );
    });
    tearDown(() => docs.deleteSync(recursive: true));

    test('un modello di estensione diversa non lascia il vecchio indietro', () async {
      // Prima del fix, `installedModelPath` cercava .task prima di .bin: un
      // .bin sostituito a un .task restava installato ma invisibile per
      // sempre, perché il vecchio .task veniva trovato per primo.
      File('${docs.path}/gemma_model.task').writeAsStringSync('vecchio modello .task');
      final newModel = File('${docs.path}/nuovo.bin')..writeAsStringSync('nuovo modello .bin');

      await GemmaService().copyFromLocalFile(newModel.path);

      expect(File('${docs.path}/gemma_model.task').existsSync(), isFalse);
      expect(File('${docs.path}/gemma_model.bin').readAsStringSync(), 'nuovo modello .bin');
      expect(await GemmaService.installedModelPath, endsWith('gemma_model.bin'));
    });

    test('un tentativo di sostituzione fallito non tocca il modello già installato', () async {
      final good = File('${docs.path}/gemma_model.task')..writeAsStringSync('modello buono e funzionante');

      final emptyArchive = File('${docs.path}/vuoto.tar.gz');
      await Stream<TarEntry>.value(TarEntry.data(
        TarHeader(name: 'LEGGIMI.txt', mode: 420, size: 3),
        Uint8List.fromList('ciao'.codeUnits),
      )).transform(tarWriter).transform(gzip.encoder).pipe(emptyArchive.openWrite());

      await expectLater(
        GemmaService().copyFromLocalFile(emptyArchive.path),
        throwsA(isA<Exception>().having((e) => '$e', 'messaggio', contains('Nessun file modello'))),
      );

      expect(good.readAsStringSync(), 'modello buono e funzionante',
          reason: 'il tentativo fallito non deve aver toccato il file buono');
      expect(await GemmaService.installedModelPath, endsWith('gemma_model.task'));
    });

    test('deleteInstalledModel rimuove il modello in qualunque formato', () async {
      for (final ext in ['.task', '.litertlm', '.bin', '.tflite']) {
        File('${docs.path}/gemma_model$ext').writeAsStringSync('x');
      }

      await GemmaService.deleteInstalledModel();

      expect(docs.listSync().whereType<File>(), isEmpty);
      expect(await GemmaService.installedModelPath, isNull);
    });
  });

  group('summarizeGemmaError', () {
    test('prende la prima riga significativa e scarta lo stack', () {
      const raw = '\n  PlatformException(RuntimeException, Failed to initialize engine)\n'
          '=== Source Location Trace ===\n at K1.a.a(SourceFile:129)\n';
      expect(summarizeGemmaError(raw), 'PlatformException(RuntimeException, Failed to initialize engine)');
    });

    test('una riga molto lunga viene accorciata', () {
      final out = summarizeGemmaError('x' * 500);
      expect(out.length, lessThan(300));
      expect(out, endsWith('…'));
    });

    test('un messaggio breve resta uguale', () {
      expect(summarizeGemmaError('Errore breve'), 'Errore breve');
      expect(summarizeGemmaError(''), '');
    });
  });

  group('importazione di un modello da .tar.gz', () {
    late Directory docs;

    setUp(() {
      docs = Directory.systemTemp.createTempSync('gemma_tar_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => docs.path,
      );
    });
    tearDown(() => docs.deleteSync(recursive: true));

    Future<File> makeArchive(String entryName, Uint8List data) async {
      final archive = File('${docs.path}/modello.tar.gz');
      await Stream<TarEntry>.value(TarEntry.data(
        TarHeader(name: entryName, mode: 420, size: data.length),
        data,
      )).transform(tarWriter).transform(gzip.encoder).pipe(archive.openWrite());
      return archive;
    }

    test('il file estratto è identico all\'originale, byte per byte', () async {
      // Regressione: scrivendo i pezzi senza attenderli, su un modello da 3,2 GB
      // il 90% dei blocchi risultava alterato ("Failed to initialize engine").
      final random = Random(7);
      final data = Uint8List.fromList(List.generate(48 * 1024 * 1024, (_) => random.nextInt(256)));
      final archive = await makeArchive('gemma2-2b-it-cpu-int8.task', data);

      await GemmaService().copyFromLocalFile(archive.path);

      final extracted = File('${docs.path}/gemma_model.task');
      expect(extracted.lengthSync(), data.length);
      final bytes = extracted.readAsBytesSync();
      var firstDiff = -1;
      for (var i = 0; i < data.length; i++) {
        if (bytes[i] != data[i]) {
          firstDiff = i;
          break;
        }
      }
      expect(firstDiff, -1, reason: 'primo byte diverso alla posizione $firstDiff');
      expect(File('${docs.path}/gemma_model.task.tmp').existsSync(), isFalse);
    });

    test('archivio senza un file modello: errore chiaro e nessun file temporaneo', () async {
      final archive = await makeArchive('LEGGIMI.txt', Uint8List.fromList(List.filled(1000, 65)));

      await expectLater(
        GemmaService().copyFromLocalFile(archive.path),
        throwsA(isA<Exception>().having((e) => '$e', 'messaggio', contains('Nessun file modello'))),
      );
      expect(docs.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });
  });
}
