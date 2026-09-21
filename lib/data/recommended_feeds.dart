/// Quanto testo contiene il feed stesso (misurato sul contenuto reale dei feed).
enum FeedTextKind {
  /// Il feed contiene l'articolo intero.
  fullText,

  /// Il feed contiene solo un estratto: l'app scarica la pagina all'apertura.
  excerpt,
}

class RecommendedFeed {
  final String title;
  final String url;
  final String category;
  final String language;
  final String description;
  final FeedTextKind textKind;

  /// Il sito limita l'accesso agli articoli: l'estrazione della pagina può
  /// restituire solo l'inizio del testo.
  final bool paywall;

  const RecommendedFeed({
    required this.title,
    required this.url,
    required this.category,
    required this.language,
    required this.description,
    this.textKind = FeedTextKind.excerpt,
    this.paywall = false,
  });
}

/// URL verificati il 2026-09-19 (risposta HTTP 200 con articoli).
/// Esclusi perché non raggiungibili a quella data: ANSA Scienza, Le Scienze,
/// Harvard Business Review, Il Post (feed generale, 403).
const recommendedFeeds = <RecommendedFeed>[
  // ── Italia ────────────────────────────────────────────────────────────────
  RecommendedFeed(
    title: 'ANSA',
    url: 'https://www.ansa.it/sito/ansait_rss.xml',
    category: 'Generale', language: 'it',
    description: 'Ultime notizie dall\'agenzia di stampa italiana.',
  ),
  RecommendedFeed(
    title: 'ANSA Mondo',
    url: 'https://www.ansa.it/sito/notizie/mondo/mondo_rss.xml',
    category: 'Generale', language: 'it',
    description: 'Notizie internazionali dall\'agenzia ANSA.',
  ),
  RecommendedFeed(
    title: 'ANSA Economia',
    url: 'https://www.ansa.it/sito/notizie/economia/economia_rss.xml',
    category: 'Economia', language: 'it',
    description: 'Economia e mercati dall\'agenzia ANSA.',
  ),
  RecommendedFeed(
    title: 'ANSA Tecnologia',
    url: 'https://www.ansa.it/sito/notizie/tecnologia/tecnologia_rss.xml',
    category: 'Tecnologia', language: 'it',
    description: 'Tecnologia e innovazione dall\'agenzia ANSA.',
  ),
  RecommendedFeed(
    title: 'ANSA Cultura',
    url: 'https://www.ansa.it/sito/notizie/cultura/cultura_rss.xml',
    category: 'Cultura', language: 'it',
    description: 'Cultura e spettacolo dall\'agenzia ANSA.',
  ),
  RecommendedFeed(
    title: 'Corriere della Sera',
    url: 'https://xml2.corriereobjects.it/rss/homepage.xml',
    category: 'Generale', language: 'it',
    description: 'Prima pagina del Corriere della Sera.',
    paywall: true,
  ),
  RecommendedFeed(
    title: 'la Repubblica',
    url: 'https://www.repubblica.it/rss/homepage/rss2.0.xml',
    category: 'Generale', language: 'it',
    description: 'Prima pagina di Repubblica.',
    paywall: true,
  ),
  RecommendedFeed(
    title: 'Il Sole 24 Ore — Economia',
    url: 'https://www.ilsole24ore.com/rss/economia.xml',
    category: 'Economia', language: 'it',
    description: 'Economia, finanza e imprese.',
    paywall: true,
  ),
  RecommendedFeed(
    title: 'Il Sole 24 Ore — Italia',
    url: 'https://www.ilsole24ore.com/rss/italia.xml',
    category: 'Generale', language: 'it',
    description: 'Attualità italiana dal Sole 24 Ore.',
    paywall: true,
  ),
  RecommendedFeed(
    title: 'Il Post — Tecnologia',
    url: 'https://www.ilpost.it/tecnologia/feed/',
    category: 'Tecnologia', language: 'it',
    description: 'Articoli discorsivi su tecnologia e internet.',
  ),
  RecommendedFeed(
    title: 'Il Post — Scienza',
    url: 'https://www.ilpost.it/scienza/feed/',
    category: 'Scienza', language: 'it',
    description: 'Scienza e ambiente, in italiano.',
  ),

  // ── Internazionale ────────────────────────────────────────────────────────
  RecommendedFeed(
    title: 'BBC News',
    url: 'https://feeds.bbci.co.uk/news/rss.xml',
    category: 'Generale', language: 'en',
    description: 'Notizie dal mondo dalla BBC.',
  ),
  RecommendedFeed(
    title: 'The Guardian — World',
    url: 'https://www.theguardian.com/world/rss',
    category: 'Generale', language: 'en',
    description: 'Notizie internazionali; estratto lungo (~900 caratteri).',
  ),
  RecommendedFeed(
    title: 'NPR News',
    url: 'https://feeds.npr.org/1001/rss.xml',
    category: 'Generale', language: 'en',
    description: 'Notizie dalla radio pubblica americana.',
  ),

  // ── Economia ──────────────────────────────────────────────────────────────
  RecommendedFeed(
    title: 'Bloomberg Technology',
    url: 'https://feeds.bloomberg.com/technology/news.rss',
    category: 'Economia', language: 'en',
    description: 'Tecnologia e mercati da Bloomberg.',
    paywall: true,
  ),

  // ── Scienza ───────────────────────────────────────────────────────────────
  RecommendedFeed(
    title: 'MIT Technology Review',
    url: 'https://www.technologyreview.com/feed/',
    category: 'Scienza', language: 'en',
    description: 'Ricerca e tecnologie emergenti.',
    textKind: FeedTextKind.fullText,
  ),

  // ── Tecnologia ────────────────────────────────────────────────────────────
  RecommendedFeed(
    title: 'Hacker News (100+ punti)',
    url: 'https://hnrss.org/frontpage?points=100',
    category: 'Tecnologia', language: 'en',
    description: 'Solo titolo e link: le notizie più votate dalla community.',
  ),
  RecommendedFeed(
    title: 'The Verge',
    url: 'https://www.theverge.com/rss/index.xml',
    category: 'Tecnologia', language: 'en',
    description: 'Tecnologia e cultura digitale.',
    textKind: FeedTextKind.fullText,
  ),
  RecommendedFeed(
    title: 'Ars Technica',
    url: 'https://feeds.arstechnica.com/arstechnica/index',
    category: 'Tecnologia', language: 'en',
    description: 'Tecnologia e scienza approfondite; estratto lungo.',
  ),
];
