import 'package:flutter_test/flutter_test.dart';
import 'package:rss_reader/services/tts_service.dart';

void main() {
  String join(List<String> c) => c.join();

  test('un testo corto resta in una sola parte', () {
    expect(TtsService.splitForSpeech('Ciao mondo.'), ['Ciao mondo.']);
    expect(TtsService.splitForSpeech(''), ['']);
  });

  test('ogni parte rispetta il limite e il testo si ricompone identico', () {
    final text = List.generate(400, (i) => 'Questa è la frase numero $i dell\'articolo.').join(' ');
    final chunks = TtsService.splitForSpeech(text, maxChars: 500);
    expect(chunks.length, greaterThan(5));
    expect(chunks.every((c) => c.length <= 500), isTrue);
    expect(join(chunks), text);
  });

  test('un articolo da 4361 caratteri (quello che Android ha rifiutato) sta sotto il limite', () {
    final text = List.generate(9, (i) => 'Paragrafo $i con abbastanza testo per fare volume. ' * 9).join('\n\n');
    expect(text.length, greaterThan(4000));
    final chunks = TtsService.splitForSpeech(text);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.length <= TtsService.maxUtteranceChars), isTrue);
    expect(join(chunks), text);
  });

  test('taglia a fine paragrafo quando può', () {
    final para = '${'Parola ' * 60}fine.';
    final text = '$para\n\n$para\n\n$para';
    final chunks = TtsService.splitForSpeech(text, maxChars: para.length * 2 + 4);
    expect(chunks.first.endsWith('\n\n'), isTrue);
    expect(join(chunks), text);
  });

  test('taglia a fine frase se non ci sono paragrafi', () {
    final text = List.generate(60, (i) => 'Frase numero $i.').join(' ');
    final chunks = TtsService.splitForSpeech(text, maxChars: 200);
    for (final c in chunks.take(chunks.length - 1)) {
      expect(c.trimRight().endsWith('.'), isTrue, reason: 'parte che non finisce a fine frase: "$c"');
    }
    expect(join(chunks), text);
  });

  test('testo senza spazi né punteggiatura: taglio netto ma senza perdite', () {
    final text = 'a' * 1000;
    final chunks = TtsService.splitForSpeech(text, maxChars: 300);
    expect(chunks.every((c) => c.length <= 300), isTrue);
    expect(join(chunks), text);
  });
}
