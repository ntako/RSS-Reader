import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:rss_reader/database/database.dart';
import 'package:rss_reader/main.dart';
import 'package:rss_reader/screens/feed_manager/feed_manager_screen.dart';
import 'package:rss_reader/providers/app_providers.dart';
import 'package:rss_reader/services/tts_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

/// Test di avvio: l'app si costruisce con un database vuoto e si può navigare
/// tra le schede principali, senza eccezioni né overflow del layout.
///
/// I plugin nativi non esistono nei widget test: database in memoria, TTS non
/// inizializzato, cartella documenti finta (il controllo del modello Gemma la
/// usa) e SharedPreferences vuote.
///
/// I font di Google non sono disponibili nei test: `google_fonts` lancia
/// un'eccezione asincrona per ognuno, che il framework conterebbe come
/// fallimento. [testApp] ignora solo quell'errore e lascia passare tutti gli altri.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  }

  late AppDatabase db;
  late Directory docsDir;

  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;

    final docs = docsDir = Directory.systemTemp.createTempSync('rss_reader_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => docs.path,
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  void testApp(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) {
      final done = Completer<void>();
      runZonedGuarded(() async {
        try {
          await body(tester);
          // Smonta l'app e lascia scorrere il timer con cui Drift chiude gli
          // stream, altrimenti il test finisce con un timer ancora pendente.
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 10));
          done.complete();
        } catch (e, st) {
          if (!done.isCompleted) done.completeError(e, st);
        }
      }, (error, stack) {
        final isFontError = error.toString().contains('GoogleFonts.config.allowRuntimeFetching');
        if (!isFontError && !done.isCompleted) done.completeError(error, stack);
      });
      return done.future;
    });
  }

  /// Schermo come l'emulatore Pixel 6 usato per provare l'app.
  void usePhoneScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
  }

  Future<void> launchApp(WidgetTester tester) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ttsServiceProvider.overrideWithValue(TtsService()),
      ],
      child: const RssReaderApp(),
    ));
    // Lascia risolvere gli stream di Drift e i controlli asincroni iniziali.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testApp('si avvia sulla lista articoli vuota con la barra di navigazione', (tester) async {
    await launchApp(tester);

    expect(find.text('Tutte le notizie'), findsOneWidget);
    expect(find.text('Nessun articolo'), findsOneWidget);
    for (final label in ['Tutte', 'Fonti', 'Salvati', 'Impostazioni']) {
      expect(find.text(label), findsOneWidget, reason: 'scheda "$label" mancante');
    }
  });

  testApp('Impostazioni con nessuna fonte non va in overflow', (tester) async {
    await launchApp(tester);

    await tester.tap(find.text('Impostazioni'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Gemma AI'), findsOneWidget);
    expect(find.text('Aggiorna in background'), findsOneWidget);
    expect(find.text('Fonti RSS'), findsOneWidget);
    // Un overflow sarebbe già fallito qui come FlutterError; la pagina deve
    // inoltre scorrere fino allo stato vuoto.
    await tester.scrollUntilVisible(
      find.text('Nessuna fonte'),
      300,
      // La pagina è una ListView; il TextField di Gemma ha un suo Scrollable interno.
      scrollable: find.descendant(
        of: find.byType(FeedManagerScreen),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(find.text('Oppure scegli tra le fonti consigliate'), findsOneWidget);
  });

  testApp('il controllo GPU in Impostazioni si può attivare senza eccezioni', (tester) async {
    await launchApp(tester);
    await tester.tap(find.text('Impostazioni'));
    await tester.pump(const Duration(milliseconds: 300));

    final gpuSwitch = find.widgetWithText(SwitchListTile, 'Usa la GPU (sperimentale)');
    expect(gpuSwitch, findsOneWidget);
    expect(tester.widget<SwitchListTile>(gpuSwitch).value, isFalse, reason: 'CPU di default');

    // Nessun modello installato: attivarla salva solo la preferenza, senza
    // tentare un caricamento — non deve quindi passare da "Verifica…".
    await tester.tap(gpuSwitch);
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.widget<SwitchListTile>(gpuSwitch).value, isTrue);
    expect(find.text('Non configurato'), findsOneWidget);
  });

  testApp('da Impostazioni si apre il catalogo delle fonti consigliate', (tester) async {
    await launchApp(tester);

    await tester.tap(find.text('Impostazioni'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await tester.tap(find.text('Fonti consigliate'));
    // Prima si chiude il menu, poi parte la transizione verso la nuova pagina.
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    expect(find.text('Fonti consigliate'), findsOneWidget); // titolo della nuova schermata
    expect(find.text('ANSA'), findsOneWidget);
    expect(find.text('Estratto'), findsWidgets);
  });

  testApp('con una fonte nel database la scheda Fonti la mostra', (tester) async {
    // Le query di Drift usano il tempo reale: fuori dall'orologio finto dei test.
    await tester.runAsync(() => db.insertFeed(FeedSourcesCompanion.insert(
        title: 'Feed di prova', url: 'https://esempio.it/rss')));

    await launchApp(tester);
    await tester.tap(find.text('Fonti'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Feed di prova'), findsWidgets);
  });

  testApp('al ritorno in primo piano mostra gli articoli scritti da un altro isolate', (tester) async {
    await launchApp(tester);
    expect(find.text('Nessun articolo'), findsOneWidget);

    // Una scrittura che Drift non notifica ai suoi stream, come quella del
    // task in background su un'altra connessione.
    await tester.runAsync(() async {
      await db.customStatement(
          "INSERT INTO feed_sources (title, url) VALUES ('Fonte esterna', 'https://e.it/rss')");
      await db.customStatement(
          "INSERT INTO articles (feed_id, guid, title, url, published_at) "
          "VALUES (1, 'g', 'Notizia scritta in background', 'https://e.it/1', strftime('%s','now'))");
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Notizia scritta in background'), findsNothing,
        reason: 'senza notifica lo stream non deve accorgersene (ipotesi del test)');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Notizia scritta in background'), findsOneWidget);
  });

  testApp('un modello Gemma che non si carica mostra "Errore" e il motivo in Impostazioni', (tester) async {
    final model = File('${docsDir.path}/gemma_model.task')..writeAsStringSync('non è un modello');
    addTearDown(() {
      if (model.existsSync()) model.deleteSync();
    });

    await launchApp(tester);
    await tester.tap(find.text('Impostazioni'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Errore'), findsOneWidget);
    expect(find.textContaining('Il modello installato non si carica'), findsOneWidget);
    expect(find.text('Verifica…'), findsNothing, reason: 'non deve restare in "Verifica…" per sempre');
  });
}
