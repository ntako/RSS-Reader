import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:archive/archive_io.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

enum GemmaStatus { notLoaded, loading, ready, error }

/// Un riassunto che non è riuscito, con la fase in cui si è fermato (creazione
/// della sessione, invio del testo, generazione…) e, per gli articoli lunghi,
/// la parte interessata. Il messaggio è pensato per essere mostrato all'utente.
class GemmaException implements Exception {
  final String stage;
  final Object cause;
  final String? part;

  const GemmaException(this.stage, this.cause, {this.part});

  GemmaException withPart(String part) => GemmaException(stage, cause, part: part);

  @override
  String toString() =>
      'Riassunto non riuscito${part != null ? ' ($part)' : ''}: $stage — $cause';
}

/// Prima riga significativa di un errore del motore (che spesso è un elenco di
/// righe di stack), accorciata: è ciò che si mostra all'utente; il resto va
/// nei dettagli.
String summarizeGemmaError(String raw) {
  final first = raw.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => raw.trim());
  return first.length > 240 ? '${first.substring(0, 240)}…' : first;
}

/// Esegue un prompt sul modello e restituisce il testo generato.
typedef PromptRunner = Future<String> Function(String prompt);

class GemmaService {
  GemmaService();

  /// Per i test: usa [runner] al posto del modello vero, già "caricato".
  @visibleForTesting
  GemmaService.withRunner(PromptRunner runner)
      : _runner = runner,
        _status = GemmaStatus.ready;

  GemmaStatus _status = GemmaStatus.notLoaded;
  String? _errorMessage;
  InferenceModel? _model;
  PromptRunner? _runner;

  GemmaStatus get status => _status;
  bool get isReady => _status == GemmaStatus.ready;
  String? get errorMessage => _errorMessage;

  // Estensioni supportate e tipo MediaPipe corrispondente
  static const _taskExts = {'.task', '.litertlm'};
  static const _binaryExts = {'.bin', '.tflite'};

  static ModelFileType _typeForExt(String ext) =>
      _taskExts.contains(ext) ? ModelFileType.task : ModelFileType.binary;

  static Future<String> _dir() async =>
      (await getApplicationDocumentsDirectory()).path;

  /// Restituisce il path del modello installato (cerca .task poi .bin).
  static Future<String?> get installedModelPath async {
    final dir = await _dir();
    for (final ext in [..._taskExts, ..._binaryExts]) {
      final f = File(p.join(dir, 'gemma_model$ext'));
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  static Future<bool> isModelDownloaded() async =>
      (await installedModelPath) != null;

  // ── Caricamento modello ───────────────────────────────────────────────────

  Future<void> loadModel() async {
    _status = GemmaStatus.loading;
    try {
      final path = await GemmaService.installedModelPath;
      if (path == null) throw Exception('Nessun modello installato.');

      final ext = p.extension(path).toLowerCase();
      final fileType = GemmaService._typeForExt(ext);

      await FlutterGemma.installModel(
        modelType: ModelType.gemmaIt,
        fileType: fileType,
      ).fromFile(path).install();

      _model = await FlutterGemmaPlugin.instance.createModel(
        modelType: ModelType.gemmaIt,
        fileType: fileType,
        maxTokens: _maxTokens,
      );

      _status = GemmaStatus.ready;
    } catch (e, st) {
      _status = GemmaStatus.error;
      _errorMessage = e.toString();
      debugPrint('[Gemma] caricamento del modello fallito: $e\n$st');
      rethrow;
    }
  }

  // ── Inferenza ─────────────────────────────────────────────────────────────

  /// Finestra di contesto (prompt + risposta) richiesta al modello.
  static const _maxTokens = 1024;

  /// Caratteri per blocco: ~600 token in italiano, così prompt e risposta
  /// restano dentro `_maxTokens`.
  static const chunkChars = 1800;

  /// Blocchi processati al massimo; oltre, il resto dell'articolo è ignorato.
  static const _maxChunks = 6;

  /// Lunghezza massima della risposta: 3-4 frasi in italiano sono ~500-700
  /// caratteri. Oltre si interrompe la generazione: un modello piccolo può
  /// non emettere mai la fine del testo e girare a vuoto fino ai token
  /// disponibili, con un risultato inutile e tempi lunghi.
  static const summaryMaxChars = 700;
  static const partialMaxChars = 350;

  /// Riassume l'articolo. Se supera un blocco lo riassume a pezzi e poi
  /// riassume i riassunti parziali. Non ritorna mai un risultato vuoto: se
  /// qualcosa non va lancia una [GemmaException] che dice dove.
  Future<String> summarize(String title, String content) async {
    if (!isReady || (_model == null && _runner == null)) {
      throw const GemmaException('modello non caricato', 'caricalo da Impostazioni');
    }
    if (content.trim().isEmpty) {
      throw const GemmaException('articolo senza testo', 'niente da riassumere');
    }

    final chunks = splitIntoChunks(content, chunkChars).take(_maxChunks).toList();
    if (chunks.length == 1) {
      return _generate(_buildPrompt(title, chunks.first), maxChars: summaryMaxChars);
    }

    final partials = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      try {
        partials.add(await _generate(
          _buildPartPrompt(title, chunks[i], i + 1, chunks.length),
          maxChars: partialMaxChars,
        ));
      } on GemmaException catch (e) {
        throw e.withPart('parte ${i + 1} di ${chunks.length}');
      }
    }

    var merged = partials.join('\n');
    if (merged.length > chunkChars) merged = merged.substring(0, chunkChars);
    try {
      return await _generate(_buildPrompt(title, merged), maxChars: summaryMaxChars);
    } on GemmaException catch (e) {
      throw e.withPart('riassunto finale');
    }
  }

  /// Versione streaming: emette token man mano che il modello li genera.
  /// Usa solo il primo blocco dell'articolo.
  Stream<String> summarizeStream(String title, String content) async* {
    if (!isReady || _model == null) return;
    if (content.trim().isEmpty) return;

    final first = splitIntoChunks(content, chunkChars).first;
    final prompt = _buildPrompt(title, first);

    InferenceModelSession? session;
    try {
      session = await _model!.createSession(
        temperature: 0.8,
        randomSeed: 1,
        topK: 1,
      );
      await session.addQueryChunk(Message(text: prompt, isUser: true));
      yield* session.getResponseAsync();
    } catch (_) {
      // ignore
    } finally {
      await session?.close();
    }
  }

  Future<String> _generate(String prompt, {required int maxChars}) async {
    final watch = Stopwatch()..start();
    try {
      final text = (await (_runner?.call(prompt) ?? _runOnModel(prompt, maxChars))).trim();
      debugPrint('[Gemma] generazione: ${watch.elapsed.inSeconds}s, '
          'prompt ${prompt.length} caratteri → risposta ${text.length} caratteri');
      if (text.isEmpty) {
        throw const GemmaException('generazione', 'il modello ha restituito una risposta vuota');
      }
      return text;
    } on GemmaException catch (e, st) {
      debugPrint('[Gemma] $e\n$st');
      rethrow;
    } catch (e, st) {
      debugPrint('[Gemma] generazione fallita: $e\n$st');
      throw GemmaException('generazione', e);
    }
  }

  Future<String> _runOnModel(String prompt, int maxChars) async {
    InferenceModelSession? session;
    var step = 'creazione della sessione';
    try {
      // topK 1 = scelta sempre del token più probabile: nei modelli piccoli
      // porta a cicli ("è è è è…"). Un campionamento moderato li evita.
      session = await _model!.createSession(
        temperature: 0.5,
        randomSeed: 1,
        topK: 40,
        topP: 0.9,
      );
      step = 'invio del testo';
      await session.addQueryChunk(Message(text: prompt, isUser: true));
      step = 'generazione';
      final out = await collectGuarded(session.getResponseAsync(), maxChars: maxChars);
      if (out.cut) {
        debugPrint('[Gemma] generazione interrotta (${out.text.length} caratteri): tetto o ciclo');
        await session.stopGeneration();
      }
      return out.text;
    } catch (e) {
      throw GemmaException(step, e);
    } finally {
      await session?.close();
    }
  }

  /// Raccoglie la risposta token per token e la interrompe se supera
  /// [maxChars] o se il modello entra in un ciclo, poi la ripulisce.
  @visibleForTesting
  static Future<({String text, bool cut})> collectGuarded(
    Stream<String> tokens, {
    required int maxChars,
  }) async {
    final buffer = StringBuffer();
    var cut = false;
    // `break` in un await-for annulla la sottoscrizione: niente token in più.
    await for (final token in tokens) {
      buffer.write(token);
      final soFar = buffer.toString();
      if (soFar.length >= maxChars || _endsWithLoop(soFar)) {
        cut = true;
        break;
      }
    }
    return (text: cleanSummary(buffer.toString(), cut: cut), cut: cut);
  }

  /// Vero se la risposta finisce con lo stesso pezzetto ripetuto molte volte
  /// ("è è è è è è" oppure "èèèèèèèè").
  static bool _endsWithLoop(String text) {
    final tail = text.length > 160 ? text.substring(text.length - 160) : text;
    return RegExp(r'(\S{1,8})(?:\s+\1){5,}\s*$').hasMatch(tail) ||
        RegExp(r'(.{1,4}?)\1{9,}$', dotAll: true).hasMatch(tail);
  }

  /// Toglie le ripetizioni a raffica e, se la risposta è stata interrotta,
  /// la taglia all'ultima frase completa invece di lasciarla a metà.
  @visibleForTesting
  static String cleanSummary(String raw, {required bool cut}) {
    var t = raw
        .replaceAllMapped(RegExp(r'(\S{1,8})(?:\s+\1){3,}'), (m) => m[1]!) // "è è è è" → "è"
        .replaceAllMapped(RegExp(r'(.{1,4}?)\1{9,}', dotAll: true), (m) => m[1]!) // "èèèèèèèè" → "è"
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cut) {
      final end = [t.lastIndexOf('.'), t.lastIndexOf('!'), t.lastIndexOf('?'), t.lastIndexOf('…')]
          .reduce((a, b) => a > b ? a : b);
      if (end >= 40) t = t.substring(0, end + 1);
    }
    return t;
  }

  /// Divide il testo in blocchi di al massimo [max] caratteri, spezzando
  /// preferibilmente ai confini di paragrafo, poi di frase.
  static List<String> splitIntoChunks(String text, int max) {
    final pieces = <String>[];
    for (final para in text.trim().split(RegExp(r'\n\s*\n'))) {
      if (para.trim().isEmpty) continue;
      if (para.length <= max) {
        pieces.add(para.trim());
        continue;
      }
      for (final sentence in para.split(RegExp(r'(?<=[.!?])\s+'))) {
        var rest = sentence;
        while (rest.length > max) {
          pieces.add(rest.substring(0, max));
          rest = rest.substring(max);
        }
        if (rest.trim().isNotEmpty) pieces.add(rest.trim());
      }
    }

    final chunks = <String>[];
    var current = StringBuffer();
    for (final piece in pieces) {
      if (current.isNotEmpty && current.length + piece.length + 2 > max) {
        chunks.add(current.toString());
        current = StringBuffer();
      }
      if (current.isNotEmpty) current.write('\n\n');
      current.write(piece);
    }
    if (current.isNotEmpty) chunks.add(current.toString());
    return chunks.isEmpty ? [text.trim()] : chunks;
  }

  String _buildPrompt(String title, String content) =>
      'Riassumi il seguente articolo in italiano in al massimo 3 frasi complete, '
      'evidenziando i punti principali. Rispondi solo con il riassunto.\n\n'
      'Titolo: $title\n\nArticolo:\n$content\n\nRiassunto:';

  String _buildPartPrompt(String title, String content, int n, int total) =>
      'Riassumi in italiano in al massimo 2 frasi questa parte ($n di $total) '
      'dell\'articolo. Rispondi solo con il riassunto.\n\n'
      'Titolo: $title\n\nParte $n:\n$content\n\nRiassunto:';

  // ── Import file locale ────────────────────────────────────────────────────

  static bool _isModelFile(String name) {
    final lower = name.toLowerCase();
    return _taskExts.any(lower.endsWith) || _binaryExts.any(lower.endsWith);
  }

  static Future<String> _destPath(String sourceName) async {
    final ext = p.extension(sourceName).toLowerCase();
    final dir = await _dir();
    return p.join(dir, 'gemma_model$ext');
  }

  Future<void> copyFromLocalFile(
    String sourcePath, {
    void Function(double progress)? onProgress,
  }) async {
    final src = File(sourcePath);
    if (!src.existsSync()) throw Exception('File non trovato: $sourcePath');

    final lower = sourcePath.toLowerCase();
    if (lower.endsWith('.zip')) {
      await _extractZip(src, onProgress: onProgress);
    } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      await _extractTarGz(src, onProgress: onProgress);
    } else {
      await _copyBin(src, onProgress: onProgress);
    }
  }

  Future<void> _copyBin(File src, {void Function(double)? onProgress}) async {
    final dest = await _destPath(p.basename(src.path));
    final tmp = File('$dest.tmp');
    try {
      final total = await src.length();
      int copied = 0;
      final sink = tmp.openWrite();
      await src.openRead().map((chunk) {
        copied += chunk.length;
        if (total > 0) onProgress?.call(copied / total);
        return chunk;
      }).pipe(sink);
      await tmp.rename(dest);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  Future<void> _extractZip(File zipFile, {void Function(double)? onProgress}) async {
    onProgress?.call(0);
    try {
      final inputStream = InputFileStream(zipFile.path);
      final archive = ZipDecoder().decodeBuffer(inputStream);
      final entry = archive.files.firstWhere(
        (f) => f.isFile && _isModelFile(f.name),
        orElse: () => throw Exception(
          'Nessun file modello nello zip. Trovati: ${archive.files.map((f) => f.name).join(', ')}',
        ),
      );
      final dest = await _destPath(p.basename(entry.name));
      final tmp = File('$dest.tmp');
      final outputStream = OutputFileStream(tmp.path);
      entry.writeContent(outputStream);
      outputStream.closeSync();
      inputStream.closeSync();
      onProgress?.call(1);
      await tmp.rename(dest);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _extractTarGz(File tarGzFile, {void Function(double)? onProgress}) async {
    onProgress?.call(0);
    final gzipStream = tarGzFile.openRead().transform(gzip.decoder);
    final reader = TarReader(gzipStream);
    File? tmp;
    try {
      bool found = false;
      while (await reader.moveNext()) {
        final entry = reader.current;
        if (entry.type == TypeFlag.reg && _isModelFile(entry.name)) {
          found = true;
          final dest = await _destPath(p.basename(entry.name));
          tmp = File('$dest.tmp');
          final total = entry.header.size;
          int written = 0;

          // Ogni pezzo va scritto PRIMA di leggere il successivo. Con
          // `sink.add(chunk)` senza attendere, il lettore tar/gzip riusa i suoi
          // buffer mentre i dati sono ancora in coda: su un modello da 3,2 GB
          // il 90% dei blocchi risultava alterato e il modello non si caricava.
          final out = await tmp.open(mode: FileMode.write);
          try {
            await for (final chunk in entry.contents) {
              await out.writeFrom(chunk);
              written += chunk.length;
              if (total > 0) onProgress?.call(written / total);
            }
            await out.flush();
          } finally {
            await out.close();
          }
          if (total > 0 && written != total) {
            throw Exception('Estrazione incompleta: $written byte su $total.');
          }
          await tmp.rename(dest);
          tmp = null;
          break;
        }
      }
      if (!found) throw Exception('Nessun file modello nel tar.gz.');
      onProgress?.call(1);
    } finally {
      await reader.cancel();
      // Se qualcosa è andato storto non lasciare sul telefono un file da GB.
      if (tmp != null && await tmp.exists()) await tmp.delete();
    }
  }

  // ── Download da URL ───────────────────────────────────────────────────────

  Future<void> downloadModel(String url, {void Function(double)? onProgress}) async {
    final filename = Uri.parse(url).pathSegments.lastOrNull ?? 'gemma_model.bin';
    final dest = await _destPath(filename);
    final tmp = File('$dest.tmp');
    try {
      final client = http.Client();
      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
      final total = response.contentLength ?? 0;
      int received = 0;
      final sink = tmp.openWrite();
      await response.stream.map((chunk) {
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
        return chunk;
      }).pipe(sink);
      await tmp.rename(dest);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  Future<void> dispose() async {
    await _model?.close();
    _model = null;
    _status = GemmaStatus.notLoaded;
  }
}
