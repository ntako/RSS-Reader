import 'package:flutter_test/flutter_test.dart';
import 'package:rss_reader/services/gemma_service.dart';

void main() {
  test('testo corto: un solo blocco', () {
    expect(GemmaService.splitIntoChunks('Ciao mondo.', 100), ['Ciao mondo.']);
  });

  test('spezza ai paragrafi e rispetta il limite', () {
    final text = List.generate(10, (i) => 'Paragrafo $i. ' * 8).join('\n\n');
    final chunks = GemmaService.splitIntoChunks(text, 300);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.length <= 300), isTrue);
  });

  test('testo senza a capo viene spezzato per frasi', () {
    final text = List.generate(40, (i) => 'Frase numero $i di prova.').join(' ');
    final chunks = GemmaService.splitIntoChunks(text, 200);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.length <= 200), isTrue);
  });

  test('frase enorme senza punteggiatura viene tagliata', () {
    final chunks = GemmaService.splitIntoChunks('a' * 1000, 300);
    expect(chunks.every((c) => c.length <= 300), isTrue);
    expect(chunks.join().length, 1000);
  });
}
