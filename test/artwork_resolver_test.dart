/// Tests unitaires — ArtworkResolver, fetchers, cache.
///
/// Aucune dépendance externe (pas de mockito, pas de build_runner).
/// Les stubs HTTP sont en Dart pur via surcharge de SimpleHttpClient.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/src/artwork/artwork_cache.dart';
import '../lib/src/artwork/artwork_fetchers.dart';
import '../lib/src/artwork/artwork_resolver.dart';
import '../lib/src/artwork/artwork_resolver_config.dart';

// ---------------------------------------------------------------------------
// Stubs HTTP
// ---------------------------------------------------------------------------

class _StubHttpClient extends SimpleHttpClient {
  _StubHttpClient(this._responses);

  final Map<String, Map<String, dynamic>?> _responses;
  final _callLog = <String>[];

  @override
  Future<Map<String, dynamic>?> getJson(Uri uri, {Duration? timeout}) async {
    _callLog.add(uri.host);
    for (final entry in _responses.entries) {
      if (uri.host.contains(entry.key)) return entry.value;
    }
    return null;
  }

  int callsTo(String hostFragment) =>
      _callLog.where((h) => h.contains(hostFragment)).length;

  List<String> get callLog => List.unmodifiable(_callLog);
}

class _DelayedStub extends SimpleHttpClient {
  _DelayedStub(this._response, {this.delayMs = 30});

  final Map<String, dynamic> _response;
  final int delayMs;
  int callCount = 0;

  @override
  Future<Map<String, dynamic>?> getJson(Uri uri, {Duration? timeout}) async {
    callCount++;
    await Future<void>.delayed(Duration(milliseconds: delayMs));
    return uri.host.contains('deezer') ? _response : null;
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

Map<String, dynamic> _deezerHit({
  String artist = 'Queen',
  String title  = 'Bohemian Rhapsody',
  String type   = 'album',
}) =>
    {
      'data': [
        {
          'title':  title,
          'artist': {'name': artist},
          'album': {
            'record_type': type,
            'cover_xl': 'https://cdn-images.deezer.com/images/cover/abc/1000x1000-000000-80-0-0.jpg',
            'cover_big': 'https://cdn-images.deezer.com/images/cover/abc/500x500.jpg',
          },
        }
      ],
    };

final _deezerNoAlbum = {
  'data': [
    {
      'title':  'Bohemian Rhapsody',
      'artist': {'name': 'Queen'},
      'album':  {
        'cover_xl':
            'https://cdn-images.deezer.com/images/cover/no_album/1000x1000.jpg',
      },
    }
  ],
};

final _deezerEmpty = {'data': <dynamic>[]};

Map<String, dynamic> _itunesHit({
  String artist = 'Queen',
  String title  = 'Bohemian Rhapsody',
}) =>
    {
      'resultCount': 1,
      'results': [
        {
          'artistName':   artist,
          'trackName':    title,
          'artworkUrl100':
              'https://is1-ssl.mzstatic.com/image/thumb/Music/xyz/100x100bb.jpg',
        }
      ],
    };

final _itunesEmpty = {'resultCount': 0, 'results': <dynamic>[]};

String _tmpDir() =>
    '/tmp/test_artwork_${DateTime.now().millisecondsSinceEpoch}';

// ---------------------------------------------------------------------------
// Helper construction
// ---------------------------------------------------------------------------

ArtworkResolver _makeResolver({
  required _StubHttpClient stub,
  List<ArtworkSource> priority = const [
    ArtworkSourceItunes(),
    ArtworkSourceDeezer(),
  ],
}) =>
    ArtworkResolver(
      config: ArtworkResolverConfig(
        priority:    priority,
        diskCacheDir: _tmpDir(),
      ),
      itunesFetcher: ItunesArtworkFetcher(http: stub),
      deezerFetcher: DeezerArtworkFetcher(http: stub),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ── DeezerArtworkFetcher ─────────────────────────────────────────────────

  group('DeezerArtworkFetcher', () {
    test('retourne cover_xl quand disponible', () async {
      final f = DeezerArtworkFetcher(
          http: _StubHttpClient({'deezer': _deezerHit()}));
      expect(
        await f.fetch(artist: 'Queen', title: 'Bohemian Rhapsody',
            timeout: const Duration(seconds: 5)),
        contains('1000x1000'),
      );
    });

    test('retourne null si data vide', () async {
      final f = DeezerArtworkFetcher(
          http: _StubHttpClient({'deezer': _deezerEmpty}));
      expect(
        await f.fetch(artist: 'X', title: 'Y',
            timeout: const Duration(seconds: 5)),
        isNull,
      );
    });

    test('rejette les URLs no_album', () async {
      final f = DeezerArtworkFetcher(
          http: _StubHttpClient({'deezer': _deezerNoAlbum}));
      expect(
        await f.fetch(artist: 'Queen', title: 'Bohemian Rhapsody',
            timeout: const Duration(seconds: 5)),
        isNull,
      );
    });

    test('retourne null si title vide', () async {
      final f = DeezerArtworkFetcher(http: _StubHttpClient({}));
      expect(
        await f.fetch(artist: 'Artist', title: '',
            timeout: const Duration(seconds: 5)),
        isNull,
      );
    });

    test('priorité album sur single', () async {
      final stub = _StubHttpClient({
        'deezer': {
          'data': [
            {
              'title': 'Bohemian Rhapsody',
              'artist': {'name': 'Queen'},
              'album': {
                'record_type': 'single',
                'cover_xl': 'https://cdn-images.deezer.com/single/1000x1000-000000-80-0-0.jpg',
              },
            },
            {
              'title': 'Bohemian Rhapsody',
              'artist': {'name': 'Queen'},
              'album': {
                'record_type': 'album',
                'cover_xl': 'https://cdn-images.deezer.com/album/1000x1000-000000-80-0-0.jpg',
              },
            },
          ],
        }
      });
      final url = await DeezerArtworkFetcher(http: stub).fetch(
          artist: 'Queen', title: 'Bohemian Rhapsody',
          timeout: const Duration(seconds: 5));
      expect(url, contains('/album/'));
    });
  });

  // ── ItunesArtworkFetcher ─────────────────────────────────────────────────

  group('ItunesArtworkFetcher', () {
    test('upscale 100x100bb → 1000x1000bb', () async {
      final f = ItunesArtworkFetcher(
          http: _StubHttpClient({'itunes': _itunesHit()}));
      expect(
        await f.fetch(artist: 'Queen', title: 'Bohemian Rhapsody',
            timeout: const Duration(seconds: 5)),
        contains('1000x1000bb.jpg'),
      );
    });

    test('retourne null si résultats vides', () async {
      final f = ItunesArtworkFetcher(
          http: _StubHttpClient({'itunes': _itunesEmpty}));
      expect(
        await f.fetch(artist: 'Unknown', title: 'Unknown',
            timeout: const Duration(seconds: 5)),
        isNull,
      );
    });

    test('retourne null si title vide', () async {
      final f = ItunesArtworkFetcher(http: _StubHttpClient({}));
      expect(
        await f.fetch(artist: 'Artist', title: '',
            timeout: const Duration(seconds: 5)),
        isNull,
      );
    });

    test('split featuring — plusieurs artistes testés', () async {
      final stub = _StubHttpClient({
        'itunes': _itunesHit(
            artist: 'Calvin Harris',
            title:  'This Is What You Came For'),
      });
      final url  = await ItunesArtworkFetcher(http: stub).fetch(
        artist:  'Calvin Harris feat. Rihanna',
        title:   'This Is What You Came For',
        timeout: const Duration(seconds: 5),
      );
      expect(url, isNotNull);
    });

    test('nettoie annotation année du titre — MARIE (1992) → MARIE', () async {
      final stub = _StubHttpClient({
        'itunes': _itunesHit(artist: 'Edith Lefel', title: 'Marie'),
      });
      final url  = await ItunesArtworkFetcher(http: stub).fetch(
        artist:  'Edith Lefel',
        title:   'MARIE (1992)',
        timeout: const Duration(seconds: 5),
      );
      expect(url, isNotNull);
    });
  });

  // ── ArtworkCache ─────────────────────────────────────────────────────────

  group('ArtworkCache', () {
    ArtworkCache make() => ArtworkCache(
          memoryCacheSize:   3,
          diskCacheDuration: const Duration(days: 1),
          diskCacheDir:      _tmpDir(),
        );

    test('buildKey est insensible à la casse et aux espaces', () {
      expect(
        ArtworkCache.buildKey('  Queen  ', 'Bohemian Rhapsody'),
        ArtworkCache.buildKey('queen', 'bohemian rhapsody'),
      );
    });

    test('get lance CacheMiss sur clé inconnue', () {
      expect(
        () => make().get('unknown|key'),
        throwsA(isA<CacheMiss>()),
      );
    });

    test('put puis get retourne la valeur', () async {
      final cache = make();
      await cache.put('queen|rhapsody', 'https://example.com/cover.jpg');
      expect(
        await cache.get('queen|rhapsody'),
        equals('https://example.com/cover.jpg'),
      );
    });

    test('put null est ignoré — get lance CacheMiss', () async {
      final cache = make();
      await cache.put('x|unknown', null);
      expect(() => cache.get('x|unknown'), throwsA(isA<CacheMiss>()));
    });

    test('invalidate supprime l\'entrée', () async {
      final cache = make();
      await cache.put('a|b', 'https://example.com/img.jpg');
      await cache.invalidate('a|b');
      expect(() => cache.get('a|b'), throwsA(isA<CacheMiss>()));
    });

    test('éviction LRU — la plus ancienne entrée est supprimée', () async {
      final cache = make(); // maxSize=3
      await cache.put('k1', 'url1');
      await cache.put('k2', 'url2');
      await cache.put('k3', 'url3');
      await cache.put('k4', 'url4'); // k1 évincé
      expect(() => cache.get('k1'), throwsA(isA<CacheMiss>()));
      expect(await cache.get('k4'), equals('url4'));
    });
  });

  // ── ArtworkResolver ──────────────────────────────────────────────────────

  group('ArtworkResolver', () {
    test('retourne URL iTunes en priorité (défaut)', () async {
      final stub = _StubHttpClient({
        'itunes': _itunesHit(),
        'deezer': _deezerHit(),
      });
      final url  = await _makeResolver(stub: stub)
          .resolve(artist: 'Queen', title: 'Bohemian Rhapsody');
      expect(url, contains('mzstatic'));
    });

    test('fallback Deezer si iTunes retourne null', () async {
      final stub = _StubHttpClient({
        'itunes': _itunesEmpty,
        'deezer': _deezerHit(),
      });
      final url  = await _makeResolver(stub: stub)
          .resolve(artist: 'Queen', title: 'Bohemian Rhapsody');
      expect(url, contains('deezer'));
    });

    test('retourne null si toutes les sources échouent', () async {
      final stub = _StubHttpClient({
        'itunes': _itunesEmpty,
        'deezer': _deezerEmpty,
      });
      expect(
        await _makeResolver(stub: stub).resolve(artist: 'X', title: 'Y'),
        isNull,
      );
    });

    test('retourne null si désactivé — aucun appel réseau', () async {
      final stub     = _StubHttpClient({});
      final resolver = ArtworkResolver(
        config:        ArtworkResolverConfig.disabled,
        itunesFetcher: ItunesArtworkFetcher(http: stub),
        deezerFetcher: DeezerArtworkFetcher(http: stub),
      );
      expect(
        await resolver.resolve(artist: 'Queen', title: 'Bohemian Rhapsody'),
        isNull,
      );
      expect(stub.callLog, isEmpty);
    });

    test('retourne null si artist et title vides', () async {
      final stub = _StubHttpClient({});
      expect(
        await _makeResolver(stub: stub).resolve(artist: '', title: ''),
        isNull,
      );
      expect(stub.callLog, isEmpty);
    });

    test('déduplication — 3 appels simultanés partagent le même Future', () async {
      final delayed  = _DelayedStub(_deezerHit());
      final resolver = ArtworkResolver(
        config:        ArtworkResolverConfig(diskCacheDir: _tmpDir()),
        itunesFetcher: ItunesArtworkFetcher(http: delayed),
        deezerFetcher: DeezerArtworkFetcher(http: delayed),
      );
      final results  = await Future.wait([
        resolver.resolve(artist: 'Queen', title: 'Bohemian Rhapsody'),
        resolver.resolve(artist: 'Queen', title: 'Bohemian Rhapsody'),
        resolver.resolve(artist: 'Queen', title: 'Bohemian Rhapsody'),
      ]);
      expect(results.toSet().length, equals(1));
    });

    test('cache — second appel sans requête réseau supplémentaire', () async {
      final stub     = _StubHttpClient({
        'itunes': _itunesHit(),
        'deezer': _deezerHit(),
      });
      final resolver = _makeResolver(stub: stub);
      await resolver.resolve(artist: 'Queen', title: 'Bohemian Rhapsody');
      final callsAfterFirst = stub.callsTo('itunes');
      await resolver.resolve(artist: 'Queen', title: 'Bohemian Rhapsody');
      expect(stub.callsTo('itunes'), equals(callsAfterFirst));
    });

    test('priorité inversée : Deezer avant iTunes', () async {
      final stub = _StubHttpClient({
        'itunes': _itunesHit(),
        'deezer': _deezerHit(),
      });
      final url  = await _makeResolver(
        stub:     stub,
        priority: [ArtworkSourceDeezer(), ArtworkSourceItunes()],
      ).resolve(artist: 'Queen', title: 'Bohemian Rhapsody');
      expect(url, contains('deezer'));
    });

    test('invalidate force une nouvelle résolution réseau', () async {
      final stub     = _StubHttpClient({
        'itunes': _itunesHit(),
        'deezer': _deezerHit(),
      });
      final resolver = _makeResolver(stub: stub);
      await resolver.resolve(artist: 'Queen', title: 'Bohemian Rhapsody');
      final callsAfterFirst = stub.callsTo('itunes');
      await resolver.invalidate(artist: 'Queen', title: 'Bohemian Rhapsody');
      await resolver.resolve(artist: 'Queen', title: 'Bohemian Rhapsody');
      expect(stub.callsTo('itunes'), greaterThan(callsAfterFirst));
    });
  });
}
