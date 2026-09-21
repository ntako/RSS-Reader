import 'package:xml/xml.dart';

import '../database/database.dart';

class OpmlFeed {
  final String title;
  final String url;
  final String category;
  final String? language;

  const OpmlFeed({
    required this.title,
    required this.url,
    required this.category,
    this.language,
  });
}

/// Import/export OPML 2.0, lo standard di scambio tra lettori RSS.
class OpmlService {
  /// Serializza i feed raggruppandoli per categoria.
  static String export(List<FeedSource> feeds) {
    final byCategory = <String, List<FeedSource>>{};
    for (final f in feeds) {
      byCategory.putIfAbsent(f.category.isEmpty ? 'Generale' : f.category, () => []).add(f);
    }

    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element('opml', attributes: {'version': '2.0'}, nest: () {
      builder.element('head', nest: () {
        builder.element('title', nest: 'Lettore RSS');
      });
      builder.element('body', nest: () {
        byCategory.forEach((category, items) {
          builder.element('outline', attributes: {'text': category, 'title': category}, nest: () {
            for (final f in items) {
              builder.element('outline', attributes: {
                'type': 'rss',
                'text': f.title,
                'title': f.title,
                'xmlUrl': f.url,
                if (f.language != null) 'language': f.language!,
              });
            }
          });
        });
      });
    });
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  /// Legge un file OPML. Le outline con `xmlUrl` sono feed; il testo
  /// dell'outline genitore diventa la categoria. Lancia [FormatException]
  /// se il file non è un OPML valido.
  static List<OpmlFeed> parse(String content) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(content);
    } on XmlException catch (e) {
      throw FormatException('File OPML non valido: ${e.message}');
    }
    final body = doc.rootElement.getElement('body');
    if (doc.rootElement.name.local != 'opml' || body == null) {
      throw const FormatException('Il file non è un OPML.');
    }

    final feeds = <OpmlFeed>[];
    void walk(XmlElement node, String category) {
      for (final o in node.childElements.where((e) => e.name.local == 'outline')) {
        final url = o.getAttribute('xmlUrl')?.trim() ?? '';
        final label = (o.getAttribute('text') ?? o.getAttribute('title'))?.trim() ?? '';
        if (url.isNotEmpty) {
          feeds.add(OpmlFeed(
            title: label.isEmpty ? url : label,
            url: url,
            category: category,
            language: o.getAttribute('language')?.trim(),
          ));
        } else {
          walk(o, label.isEmpty ? category : label);
        }
      }
    }

    walk(body, 'Generale');
    return feeds;
  }
}
