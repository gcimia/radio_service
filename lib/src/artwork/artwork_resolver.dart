/// ArtworkResolver — résolution automatique de pochettes d'album.
library;

import 'artwork_cache.dart';
import 'artwork_fetchers.dart';
import 'artwork_resolver_config.dart';

class ArtworkResolver {
  ArtworkResolver({
    required ArtworkResolverConfig config,
    ArtworkCache? cache,
    ItunesArtworkFetcher? itunesFetcher,
    DeezerArtworkFetcher? deezerFetcher,
  })  : _config  = config,
        _cache   = cache ?? ArtworkCache(
          memoryCacheSize:   config.memoryCacheSize,
          diskCacheDuration: config.diskCacheDuration,
          diskCacheDir:      config.diskCacheDir,
        ),
        _itunes  = itunesFetcher ?? const ItunesArtworkFetcher(),
        _deezer  = deezerFetcher ?? const DeezerArtworkFetcher();

  final ArtworkResolverConfig  _config;
  final ArtworkCache           _cache;
  final ItunesArtworkFetcher   _itunes;
  final DeezerArtworkFetcher   _deezer;

  /// Dédupplication des requêtes en vol — même clé = même Future partagé.
  final Map<String, Future<String?>> _inflight = {};

  // ---------------------------------------------------------------------------
  // API publique
  // ---------------------------------------------------------------------------

  /// Résout l'artwork pour [artist] / [title].
  /// Retourne null si désactivé, si les deux champs sont vides,
  /// ou si aucune source ne retourne de résultat.
  Future<String?> resolve({String? artist, String? title}) async {
    if (!_config.enabled) return null;

    final a = (artist ?? '').trim();
    final t = (title  ?? '').trim();
    if (a.isEmpty && t.isEmpty) return null;

    final key = ArtworkCache.buildKey(a, t);

    // 1. Cache mémoire ou disque
    try {
      return await _cache.get(key);
    } on CacheMiss {
      // pas encore en cache → on résout
    }

    // 2. Dédupplication des requêtes en vol
    if (_inflight.containsKey(key)) return _inflight[key];

    final future = _resolveFromSources(artist: a, title: t, key: key);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<void> invalidate({String? artist, String? title}) =>
      _cache.invalidate(ArtworkCache.buildKey(artist, title));

  Future<void> clearCache() => _cache.clear();

  // ---------------------------------------------------------------------------
  // Résolution interne
  // ---------------------------------------------------------------------------

  Future<String?> _resolveFromSources({
    required String artist,
    required String title,
    required String key,
  }) async {
    // Lancement parallèle de toutes les sources configurées.
    // Réduit le temps d'attente total — iTunes et Deezer cherchent simultanément.
    // Le premier résultat valide selon l'ordre de priorité est retenu.
    final futures = _config.priority.map((source) {
      final fetcher = switch (source) {
        ArtworkSourceItunes() => _itunes,
        ArtworkSourceDeezer() => _deezer,
      };
      return fetcher.fetch(
        artist:  artist,
        title:   title,
        timeout: _config.requestTimeout,
      ).catchError((_) => null as String?);
    }).toList();

    final results = await Future.wait(futures);

    // Sélection selon l'ordre de priorité configuré — on prend le premier non-null
    String? url;
    for (var i = 0; i < results.length; i++) {
      if (results[i] != null) {
        url = results[i];
        break;
      }
    }

    if (url != null) await _cache.put(key, url);
    return url;
  }
}