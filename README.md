# 📰 Lettore RSS — Flutter App

App Flutter completamente locale per leggere feed RSS con riassunti AI (Gemma) e sintesi vocale.

## ✨ Funzionalità

- **Feed RSS/Atom** — aggiungi qualsiasi fonte RSS/Atom
- **Lettura offline** — gli articoli vengono salvati localmente in SQLite
- **Sintesi vocale** — ascolta gli articoli con TTS nativo (italiano)
- **Riassunto AI** — riassunti generati da Gemma on-device (slot pronto)
- **Preferiti** — salva gli articoli che vuoi rileggere
- **Design editoriale** — tema scuro con tipografia Playfair Display + Lora

---

## 🚀 Setup rapido

### 1. Clona e installa dipendenze

```bash
flutter pub get
```

### 2. Genera il codice Drift (database)

```bash
dart run build_runner build --delete-conflicting-outputs
```

### 3. Avvia l'app

```bash
flutter run
```

---

## 🤖 Attivare Gemma AI (riassunti)

### Passo 1 — Aggiungi flutter_gemma al pubspec.yaml

```yaml
dependencies:
  flutter_gemma: ^0.2.0
```

### Passo 2 — Scarica il modello

Scarica da [Kaggle](https://www.kaggle.com/models/google/gemma) o Hugging Face:

| Modello | Dimensione | Consigliato per |
|---------|-----------|-----------------|
| `gemma-3-1b-it-int4.bin` | ~600 MB | Tutti i device |
| `gemma-3-2b-it-int4.bin` | ~1.3 GB | Device con 4GB+ RAM |

Posiziona il file in:
- **Android**: `/data/data/<package>/files/gemma_model.bin`
- **iOS**: cartella documenti dell'app

### Passo 3 — Abilita il codice in GemmaService

Apri `lib/services/gemma_service.dart` e decommentare le sezioni marcate `[GEMMA]`.

Chiama `loadModel(path)` all'avvio dell'app (es. in uno splash screen).

---

## 📁 Struttura del progetto

```
lib/
├── main.dart                        # Entry point
├── theme/
│   └── app_theme.dart               # Colori, font, tema dark
├── models/
│   ├── tables.dart                  # Tabelle Drift (FeedSources, Articles)
│   └── database.dart                # Database + query
├── services/
│   ├── rss_service.dart             # Fetch + parsing RSS/Atom
│   ├── tts_service.dart             # Text-to-speech wrapper
│   └── gemma_service.dart           # AI riassunto (stub → Gemma)
├── providers/
│   └── app_providers.dart           # Riverpod providers
├── widgets/
│   └── common_widgets.dart          # ArticleCard, FeedTile, TtsPlayerBar
└── screens/
    ├── home_screen.dart             # Nav principale
    ├── feed_manager/                # Gestione fonti RSS
    ├── article_list/                # Lista articoli
    └── article_reader/              # Lettura + TTS + AI summary
```

---

## 📦 Dipendenze principali

| Pacchetto | Uso |
|-----------|-----|
| `webfeed` | Parsing RSS/Atom |
| `http` | Download feed |
| `drift` + `drift_flutter` | Database SQLite locale |
| `flutter_tts` | Sintesi vocale nativa |
| `flutter_riverpod` | State management |
| `google_fonts` | Playfair Display, Lora, Space Grotesk |
| `cached_network_image` | Immagini con cache |
| `html` | Estrazione testo da HTML |

---

## 🎨 Design

- Tema: **dark editoriale** con palette ambra/avorio su nero caldo
- Font: **Playfair Display** (titoli), **Lora** (corpo), **Space Grotesk** (label/meta)
- Accent color: `#D4A853` (ambra)

---

## ⚠️ Note

- Il database viene pulito automaticamente dagli articoli più vecchi di 30 giorni (non preferiti)
- La sintesi vocale usa il motore TTS nativo del dispositivo: assicurarsi di avere il pacchetto lingua italiana installato
- Gemma richiede Android API 24+ / iOS 16+
