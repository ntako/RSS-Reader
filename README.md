# 📰 Lettore RSS — Flutter App

App Flutter completamente locale per leggere feed RSS con testo completo, ricerca, riassunti AI (Gemma on-device) e sintesi vocale. Target: Android (API 24+).

## ✨ Funzionalità

- **Feed RSS/Atom** — aggiungi una fonte a mano, scegli tra le **fonti consigliate** o importa/esporta un file **OPML**
- **Testo completo** — se il feed dà solo un estratto, l'app scarica la pagina dell'articolo e ne estrae il testo (vedi [Come funziona il testo completo](#-come-funziona-il-testo-completo))
- **Lettura offline** — articoli e testi salvati in SQLite
- **Ricerca full-text** — su titolo, estratto e testo pieno, anche per prefisso e senza tener conto degli accenti
- **Deduplica** — la stessa notizia arrivata da più fonti compare una volta sola in "Tutte le notizie"
- **Aggiornamento in background** — refresh periodico anche ad app chiusa, con notifica per le fonti scelte
- **Sintesi vocale** — ascolta articoli o intere playlist con il TTS nativo
- **Riassunto AI** — Gemma on-device, anche per articoli lunghi (riassunto a blocchi)
- **Preferiti**, **design editoriale** scuro (Playfair Display + Lora)

---

## 🚀 Setup rapido

Requisiti: Flutter 3.41+ e un JDK **17 o 21** (Gradle 8.14 non supporta ancora il JDK 25).

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # genera il codice Drift (database.g.dart, non è in git)
flutter run
```

Ogni volta che cambi `lib/models/tables.dart` rigenera il codice con il secondo comando e incrementa `schemaVersion` in `lib/database/database.dart`, aggiungendo il passo di migrazione.

---

## 📱 Provare l'app su un emulatore Android (Linux)

Non serve Android Studio: bastano gli strumenti a riga di comando. Le istruzioni sono quelle usate su Ubuntu; i percorsi sono in `~/Android/Sdk`, quindi non serve `sudo` (tranne per KVM, se manca).

### 1. Verifica la virtualizzazione (KVM)

```bash
test -r /dev/kvm -a -w /dev/kvm && echo "KVM ok" || echo "KVM non accessibile"
```

Se non è accessibile: `sudo usermod -aG kvm $USER` e rientra nella sessione. Senza KVM l'emulatore è quasi inutilizzabile.

### 2. Installa l'SDK Android

```bash
export ANDROID_HOME=$HOME/Android/Sdk
mkdir -p $ANDROID_HOME/cmdline-tools && cd /tmp
curl -LO https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
unzip -q commandlinetools-linux-11076708_latest.zip -d $ANDROID_HOME/cmdline-tools
mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest

export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH
yes | sdkmanager --licenses      # accetta le licenze Android
sdkmanager "platform-tools" "emulator" "platforms;android-36" \
           "build-tools;36.0.0" "system-images;android-35;google_apis;x86_64"
```

Il download è di alcuni GB. Aggiungi gli `export` di `ANDROID_HOME` e `PATH` a `~/.bashrc` o `~/.zshrc` per non doverli ripetere.

### 3. Configura Flutter

```bash
flutter config --android-sdk $HOME/Android/Sdk --jdk-dir /usr/lib/jvm/java-21-openjdk-amd64
flutter doctor --android-licenses
flutter doctor                   # "Android toolchain" deve essere ✓
```

### 4. Crea l'emulatore

```bash
avdmanager create avd -n rss_test -k "system-images;android-35;google_apis;x86_64" -d pixel_6
```

Con poca RAM libera abbassa la memoria dell'emulatore a 2 GB: in `~/.android/avd/rss_test.avd/config.ini` imposta `hw.ramSize=2048`.

### 5. Avvia emulatore e app

```bash
emulator -avd rss_test -no-audio &      # aspetta la schermata Home di Android
flutter run -d emulator-5554            # r = hot reload, R = hot restart, q = esci
```

La **prima build è lenta** (circa 13 minuti nella prova fatta): Gradle scarica da solo NDK, CMake e altre piattaforme. Le successive richiedono circa 1 minuto. Il primo avvio dell'app sull'emulatore può durare 30 secondi con la schermata di Flutter ferma.

### Poca RAM?

Se la macchina va in swap, limita Gradle creando `~/.gradle/gradle.properties` (sovrascrive `android/gradle.properties`, il file del progetto resta intatto):

```properties
org.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=512m
kotlin.daemon.jvmargs=-Xmx1g
org.gradle.workers.max=2
```

Durante la prima build chiudi l'emulatore: la build non ne ha bisogno. Al termine ferma il demone con `cd android && ./gradlew --stop`.

### Comandi utili

```bash
adb devices                                                       # emulatori/dispositivi collegati
adb install -r build/app/outputs/flutter-apk/app-debug.apk        # dopo `flutter build apk --debug`
adb logcat -s flutter:V AndroidRuntime:E                          # solo log dell'app
adb exec-out screencap -p > shot.png                              # screenshot
emulator -list-avds ; adb emu kill                                # elenca / chiudi
```

Se compare la finestra Google "Try out your stylus" dopo aver scritto nell'app, è del sistema Android dell'emulatore: chiudila con *Cancel*.

---

## 📖 Usare l'app

- **Aggiungere fonti** — *Impostazioni → ⋮ → Fonti consigliate*: 19 feed italiani e internazionali già verificati, con badge **Testo completo** / **Estratto**, **Paywall** e lingua. Oppure il pulsante **+** per un URL a mano.
- **Importare/esportare OPML** — *Impostazioni → ⋮ → Importa OPML / Esporta OPML*. L'import salta le fonti già presenti e legge anche gli OPML annidati di altri lettori.
- **Cercare** — lente in alto nella lista articoli.
- **Ascoltare** — *Ascolta articolo* nel reader, oppure l'icona playlist nella lista per leggere tutti gli articoli.
- **Notifiche per le nuove notizie** — in *Impostazioni* attiva **Aggiorna in background** (ogni 1, 3, 6 o 12 ore), poi tocca la **campanella** sulle fonti che ti interessano. Al primo uso Android chiede il permesso per le notifiche. Arriva un'unica notifica di riepilogo; non vengono segnalati i feed appena aggiunti né i duplicati di notizie già arrivate da un'altra fonte.

### 🤖 Riassunti con Gemma

Gemma è già integrato (`flutter_gemma`), serve solo il modello:

1. Scarica da [Kaggle](https://www.kaggle.com/models/google/gemma) il formato **LiteRT**, ad esempio `gemma-2-2b-it-cpu-int4` (~1,3 GB). Sono supportati `.task`, `.bin` e `.tflite`, anche dentro `.zip` o `.tar.gz`.
2. In *Impostazioni → Gemma AI* scegli **Scegli file locale** oppure incolla un **URL download**.
3. Nel reader tocca **Riassunto AI**.

Gli articoli lunghi sono divisi in blocchi da ~1800 caratteri (massimo 6): ogni blocco viene riassunto e poi i riassunti parziali vengono riassunti di nuovo. La finestra di contesto è di 1024 token (`_maxTokens` in `lib/services/gemma_service.dart`): se il modello non parte su un telefono con poca RAM, abbassa `_maxTokens` e `chunkChars`. Su un emulatore Gemma può essere molto lento o non funzionare: meglio un dispositivo reale.

---

## 🔍 Come funziona il testo completo

1. Se il feed contiene già l'articolo (`content:encoded` o `<content>` Atom, più lungo dell'estratto di almeno 200 caratteri), lo usa.
2. Altrimenti, quando apri un articolo con estratto corto (< 1500 caratteri), scarica la pagina e cerca il testo prima nel JSON-LD (`articleBody`), poi con un'euristica sul DOM (`<article>` o il blocco con più paragrafi, scartando menu, "correlati", condivisioni…).
3. Se il risultato è sotto i 300 caratteri (paywall, pagina caricata via JavaScript, blocco anti-bot) l'app mantiene l'estratto e offre **Riprova**.
4. Il testo estratto viene salvato in `content`: reader, TTS, Gemma e ricerca lo usano da quel momento.

L'estrazione è un'euristica: alcuni siti daranno testo incompleto o rumoroso. Se un sito non funziona, il punto da correggere è `lib/services/article_extractor.dart`.

---

## 🧪 Test

```bash
flutter test
```

I test sul database e sul refresh usano SQLite reale in memoria e un server HTTP locale, senza rete. Su Linux serve `libsqlite3.so.0` (di solito già presente; i test la caricano direttamente, senza il pacchetto `libsqlite3-dev`).

`test/widget_test.dart` è il **test di avvio**: costruisce l'app con un database vuoto, naviga tra le schede e apre le fonti consigliate, verificando che non ci siano eccezioni né overflow del layout (con uno schermo come il Pixel 6 dell'emulatore). Sostituisce i plugin nativi con versioni finte e ignora solo gli errori di `google_fonts`, che nei test non può scaricare i font.

**Stato della verifica** — provato su emulatore Android 15 (x86_64) e con i test automatici: avvio, schermata Impostazioni, fonti consigliate, aggiunta feed, lista articoli, estrazione del testo completo su ANSA, ricerca. **Non ancora verificati su dispositivo**: aggiornamento in background e notifiche, TTS, riassunti Gemma, import/export OPML con il selettore file, estrazione su siti con paywall, migrazione di un database già esistente.

---

## 📁 Struttura del progetto

```
lib/
├── main.dart                          # Entry point: inizializza notifiche e task in background
├── theme/app_theme.dart               # Colori, font, tema dark
├── models/tables.dart                 # Tabelle Drift (FeedSources, Articles)
├── database/database.dart             # Database, migrazioni, indice FTS5, ricerca, deduplica
├── data/recommended_feeds.dart        # Catalogo delle fonti consigliate
├── services/
│   ├── rss_service.dart               # Fetch RSS/Atom, GET condizionale (ETag), pulizia articoli
│   ├── article_extractor.dart         # Testo completo dalla pagina dell'articolo
│   ├── duplicate_detector.dart        # Riconosce la stessa notizia su più fonti
│   ├── opml_service.dart              # Import/export OPML
│   ├── background_refresh.dart        # Task periodico (WorkManager) e raccolta novità
│   ├── notification_service.dart      # Notifica di riepilogo
│   ├── app_settings.dart              # Impostazioni (shared_preferences)
│   ├── tts_service.dart / tts_background.dart   # Text-to-speech e servizio in foreground
│   └── gemma_service.dart             # Riassunti on-device
├── providers/app_providers.dart       # Provider Riverpod
├── widgets/common_widgets.dart        # ArticleCard, TtsPlayerBar…
└── screens/
    ├── home_screen.dart               # Navigazione principale
    ├── article_list/                  # Lista articoli
    ├── article_reader/                # Lettura, TTS, riassunto AI
    ├── search/                        # Ricerca full-text
    └── feed_manager/                  # Impostazioni: fonti, consigliate, background, Gemma
test/                                  # Test unitari e di integrazione (vedi sopra)
```

---

## 📦 Dipendenze principali

| Pacchetto | Uso |
|-----------|-----|
| `webfeed_plus` | Parsing RSS/Atom (fork aggiornato di `webfeed`, compatibile con `xml` 6) |
| `xml` | Import/export OPML |
| `http` | Download di feed e pagine |
| `html` | Estrazione del testo dall'HTML |
| `drift` + `drift_flutter` | Database SQLite locale, con FTS5 per la ricerca |
| `workmanager` | Aggiornamento periodico in background |
| `flutter_local_notifications` | Notifica dei nuovi articoli |
| `shared_preferences` | Impostazioni dell'aggiornamento in background |
| `flutter_tts`, `flutter_foreground_task` | Sintesi vocale, anche a schermo spento |
| `flutter_gemma` | Riassunti on-device |
| `flutter_riverpod` | State management |
| `google_fonts`, `cached_network_image` | Tipografia e immagini con cache |

---

## 🎨 Design

- Tema: **dark editoriale** con palette ambra/avorio su nero caldo
- Font: **Playfair Display** (titoli), **Lora** (corpo), **Space Grotesk** (label/meta)
- Accent color: `#D4A853` (ambra)

---

## ⚠️ Note

- Gli articoli non preferiti vengono eliminati dopo 30 giorni (`AppDatabase.retentionDays`), a ogni aggiornamento dei feed. Gli articoli più vecchi di 30 giorni ancora presenti nel feed non vengono reinseriti.
- I duplicati sono nascosti solo in "Tutte le notizie", nella playlist e nella ricerca; restano visibili nel feed di origine. Il confronto tra titoli è un'euristica (soglie in `duplicate_detector.dart`) e può sbagliare su titoli ricorrenti come "Meteo oggi".
- Il database usa la modalità WAL: l'app e il task in background sono due processi che aprono lo stesso file.
- Android decide quando eseguire i task periodici (minimo 15 minuti). Alcuni produttori (Xiaomi, Samsung…) bloccano i task in background: se le notifiche non arrivano, controlla le impostazioni di risparmio energetico dell'app.
- La sintesi vocale usa il motore TTS nativo: assicurati di avere il pacchetto lingua italiana installato.
- Gemma richiede Android API 24+.
