/// Tests unitaires — MetadataParser et logique de déduplication.
///
/// RadioService lui-même n'est pas testé directement car il orchestre
/// des composants réseau (IcyStreamReader, AudioProxyServer) — ces
/// composants ont leurs propres tests d'intégration.
/// Ce fichier teste la logique pure : parsing ICY, déduplication, génération.
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/src/metadata/metadata_parser.dart';
import '../lib/src/metadata/player_metadata.dart';

void main() {
  // ── MetadataParser ────────────────────────────────────────────────────────

  group('MetadataParser', () {
    late MetadataParser parser;

    setUp(() => parser = MetadataParser());

    test('ignore les événements non-metadata', () {
      expect(parser.parse({'type': 'state', 'value': 'playing'}), isNull);
      expect(parser.parse({'type': 'position', 'isLive': true}), isNull);
    });

    test('ignore les événements sans source', () {
      expect(parser.parse({'type': 'metadata'}), isNull);
    });

    test('parse icy_info — format "ARTISTE - TITRE"', () {
      final m = parser.parse({
        'type':     'metadata',
        'source':   'icy_info',
        'rawTitle': 'QUEEN - BOHEMIAN RHAPSODY',
      });
      expect(m, isNotNull);
      expect(m!.artist, equals('QUEEN'));
      expect(m.title,   equals('BOHEMIAN RHAPSODY'));
    });

    test('parse icy_info — titre sans artiste', () {
      final m = parser.parse({
        'type':     'metadata',
        'source':   'icy_info',
        'rawTitle': 'BOHEMIAN RHAPSODY',
      });
      expect(m, isNotNull);
      expect(m!.artist, isNull);
      expect(m.title,   equals('BOHEMIAN RHAPSODY'));
    });

    test('parse icy_info — rawTitle vide retourne null', () {
      final m = parser.parse({
        'type':     'metadata',
        'source':   'icy_info',
        'rawTitle': '',
      });
      expect(m, isNull);
    });

    test('parse icy_header — station name et genre', () {
      final m = parser.parse({
        'type':        'metadata',
        'source':      'icy_header',
        'stationName': 'Bel Radio',
        'stationGenre':'Zouk',
      });
      expect(m, isNotNull);
      expect(m!.stationName,  equals('Bel Radio'));
      expect(m.stationGenre, equals('Zouk'));
    });

    test('reset efface l\'état du parser', () {
      parser.parse({
        'type': 'metadata', 'source': 'icy_info',
        'rawTitle': 'QUEEN - BOHEMIAN RHAPSODY',
      });
      parser.reset();
      final m = parser.current;
      expect(m.artist, isNull);
      expect(m.title,  isNull);
    });

    test('icy_info suivant un icy_header conserve les infos station', () {
      parser.parse({
        'type': 'metadata', 'source': 'icy_header',
        'stationName': 'Bel Radio',
      });
      parser.parse({
        'type': 'metadata', 'source': 'icy_info',
        'rawTitle': 'QUEEN - BOHEMIAN RHAPSODY',
      });
      final m = parser.current;
      expect(m.stationName, equals('Bel Radio'));
      expect(m.artist,      equals('QUEEN'));
      expect(m.title,       equals('BOHEMIAN RHAPSODY'));
    });
  });

  // ── Logique de déduplication (via _isNonMusical patterns) ─────────────────

  group('Détection non-musical', () {
    // On teste la logique métier directement sans passer par RadioService
    // (qui nécessite le natif). Le pattern est le même que dans radio_service.dart.

    final pattern = RegExp(
      r'(liner|jingle|top\s+h|horaire|publicite|pub\s+|spot\s+|'
      r'speakerine|speakerin|promo\s+|stores\s+|billboard)',
      caseSensitive: false,
    );

    bool isNonMusical(PlayerMetadata m) {
      final hasArtist = m.artist != null && m.artist!.trim().isNotEmpty;
      if (hasArtist) return false;
      return pattern.hasMatch(m.title ?? '');
    }

    test('liner sans artiste → non-musical', () {
      final m = const PlayerMetadata(title: 'LINER : BEL RADIO', artist: null);
      expect(isNonMusical(m), isTrue);
    });

    test('jingle sans artiste → non-musical', () {
      final m = const PlayerMetadata(title: 'JINGLE 001', artist: null);
      expect(isNonMusical(m), isTrue);
    });

    test('titre musical sans artiste → musical', () {
      final m = const PlayerMetadata(title: 'BILONGO', artist: null);
      expect(isNonMusical(m), isFalse);
    });

    test('titre avec artiste présent → toujours musical', () {
      final m = const PlayerMetadata(
          title: 'LINER : BEL RADIO', artist: 'Quelqu\'un');
      expect(isNonMusical(m), isFalse);
    });

    test('BEL RADIO liner 017 1 → non-musical', () {
      final m = const PlayerMetadata(
          title: 'BEL RADIO liner 017 1', artist: null);
      expect(isNonMusical(m), isTrue);
    });
  });

  // ── PlayerMetadata ────────────────────────────────────────────────────────

  group('PlayerMetadata', () {
    test('copyWith préserve les champs non modifiés', () {
      const m = PlayerMetadata(
        title: 'Bohemian Rhapsody', artist: 'Queen',
        stationName: 'Bel Radio',
      );
      final copy = m.copyWith(artworkUrl: 'https://example.com/cover.jpg');
      expect(copy.title,       equals('Bohemian Rhapsody'));
      expect(copy.artist,      equals('Queen'));
      expect(copy.stationName, equals('Bel Radio'));
      expect(copy.artworkUrl,  equals('https://example.com/cover.jpg'));
    });

    test('copyWith peut effacer artworkUrl avec null explicite', () {
      const m = PlayerMetadata(
          title: 'Test', artworkUrl: 'https://example.com/old.jpg');
      final copy = m.copyWith(artworkUrl: null);
      expect(copy.artworkUrl, isNull);
    });
  });
}
