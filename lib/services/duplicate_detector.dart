/// Articolo già noto, contro cui confrontare i nuovi arrivi.
class KnownArticle {
  final int id;
  final int feedId;
  final String url;
  final String title;

  const KnownArticle({
    required this.id,
    required this.feedId,
    required this.url,
    required this.title,
  });
}

/// Riconosce la stessa notizia arrivata da più feed.
///
/// - Stesso URL (dopo la normalizzazione): duplicato certo, anche nello
///   stesso feed o tra sezioni diverse dello stesso sito.
/// - Titoli simili da feed diversi: euristica basata sulla somiglianza di
///   Jaccard tra le parole significative. Può sbagliare su titoli ricorrenti
///   ("Meteo oggi", "Serie A: i risultati"), per questo la soglia è alta e
///   servono almeno [minTokens] parole.
class DuplicateDetector {
  static const similarityThreshold = 0.6;
  static const minTokens = 4;

  static const _stopwords = {
    'della', 'delle', 'dello', 'degli', 'nella', 'nelle', 'nello', 'dopo',
    'sono', 'come', 'sulla', 'sulle', 'anche', 'that', 'this', 'with', 'from',
    'have', 'will', 'your', 'about', 'after', 'their',
  };

  /// Restituisce l'id dell'articolo di cui [url]/[title] è un duplicato,
  /// oppure null se è una notizia nuova.
  static int? findOriginal({
    required int feedId,
    required String url,
    required String title,
    required Iterable<KnownArticle> known,
  }) {
    final normUrl = normalizeUrl(url);
    final tokens = titleTokens(title);

    for (final k in known) {
      if (normalizeUrl(k.url) == normUrl) return k.id;
    }
    if (tokens.length < minTokens) return null;

    for (final k in known) {
      if (k.feedId == feedId) continue;
      final other = titleTokens(k.title);
      if (other.length < minTokens) continue;
      if (jaccard(tokens, other) >= similarityThreshold) return k.id;
    }
    return null;
  }

  /// Host senza "www.", percorso senza slash finale, parametri di tracking
  /// rimossi, fragment ignorato.
  static String normalizeUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return url.trim().toLowerCase();

    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    var path = uri.path;
    if (path.length > 1 && path.endsWith('/')) path = path.substring(0, path.length - 1);

    final params = Map.fromEntries(uri.queryParameters.entries.where((e) {
      final k = e.key.toLowerCase();
      return !k.startsWith('utm_') && k != 'fbclid' && k != 'ref' && k != 'gclid';
    }));
    final sorted = params.keys.toList()..sort();
    final query = sorted.map((k) => '$k=${params[k]}').join('&');
    return '$host$path${query.isEmpty ? '' : '?$query'}';
  }

  static Set<String> titleTokens(String title) {
    final cleaned = _stripDiacritics(title.toLowerCase())
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    return cleaned
        .split(' ')
        .where((t) => t.length >= 4 && !_stopwords.contains(t))
        .toSet();
  }

  static double jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final inter = a.intersection(b).length;
    return inter / (a.length + b.length - inter);
  }

  static String _stripDiacritics(String s) {
    const from = 'àáâäãåèéêëìíîïòóôöõùúûüýÿçñ';
    const to = 'aaaaaaeeeeiiiiooooouuuuyycn';
    final buf = StringBuffer();
    for (final ch in s.split('')) {
      final i = from.indexOf(ch);
      buf.write(i >= 0 ? to[i] : ch);
    }
    return buf.toString();
  }
}
