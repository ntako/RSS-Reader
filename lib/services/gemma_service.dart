import 'dart:async';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';

enum GemmaStatus { notLoaded, loading, ready, error }

class GemmaService {
  GemmaStatus _status = GemmaStatus.notLoaded;
  String? _errorMessage;
  InferenceModel? _model;

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
        maxTokens: 512,
      );

      _status = GemmaStatus.ready;
    } catch (e) {
      _status = GemmaStatus.error;
      _errorMessage = e.toString();
      rethrow;
    }
  }

  // ── Inferenza ─────────────────────────────────────────────────────────────

  Future<String?> summarize(String title, String content) async {
    if (!isReady || _model == null) return null;
    if (content.trim().isEmpty) return null;

    final truncated = content.length > 3000 ? content.substring(0, 3000) : content;
    final prompt = _buildPrompt(title, truncated);

    InferenceModelSession? session;
    try {
      session = await _model!.createSession(
        temperature: 0.8,
        randomSeed: 1,
        topK: 1,
      );
      await session.addQueryChunk(Message(text: prompt, isUser: true));
      final result = await session.getResponse();
      return result.trim().isEmpty ? null : result.trim();
    } catch (_) {
      return null;
    } finally {
      await session?.close();
    }
  }

  /// Versione streaming: emette token man mano che il modello li genera.
  Stream<String> summarizeStream(String title, String content) async* {
    if (!isReady || _model == null) return;
    if (content.trim().isEmpty) return;

    final truncated = content.length > 3000 ? content.substring(0, 3000) : content;
    final prompt = _buildPrompt(title, truncated);

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

  String _buildPrompt(String title, String content) =>
      'Riassumi il seguente articolo in italiano in 3-4 frasi concise, '
      'evidenziando i punti principali. Sii diretto e informativo.\n\n'
      'Titolo: $title\n\nArticolo:\n$content\n\nRiassunto:';

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
    try {
      final gzipStream = tarGzFile.openRead().transform(gzip.decoder);
      final reader = TarReader(gzipStream);
      bool found = false;
      while (await reader.moveNext()) {
        final entry = reader.current;
        if (entry.type == TypeFlag.reg && _isModelFile(entry.name)) {
          found = true;
          final dest = await _destPath(p.basename(entry.name));
          final tmp = File('$dest.tmp');
          final total = entry.header.size;
          int written = 0;
          final sink = tmp.openWrite();
          await for (final chunk in entry.contents) {
            sink.add(chunk);
            written += chunk.length;
            if (total > 0) onProgress?.call(written / total);
          }
          await sink.flush();
          await sink.close();
          await tmp.rename(dest);
          break;
        }
      }
      await reader.cancel();
      if (!found) throw Exception('Nessun file modello nel tar.gz.');
      onProgress?.call(1);
    } catch (e) {
      rethrow;
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
