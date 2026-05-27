/// Cache artwork à deux niveaux : mémoire (LRU) + disque (JSON).
///
/// Aucune dépendance externe : [dart:io], [dart:convert], [dart:async].
/// Le cache disque utilise un simple fichier JSON dans le répertoire
/// de cache de l'application, résolu via [path_provider] — la seule
/// dépendance conservée car elle est déjà requise par le plugin Flutter
/// pour accéder aux chemins système de manière cross-platform.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

// ---------------------------------------------------------------------------
// Entrée de cache
// ---------------------------------------------------------------------------

class _Entry {
  _Entry({required this.url, required this.expiresAt});

  factory _Entry.fromJson(Map<String, dynamic> j) => _Entry(
    url: j['url'] as String?,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(j['expiresAt'] as int),
  );

  /// URL résolue. null = résultat négatif connu (évite les requêtes répétées).
  final String? url;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
    'url': url,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
  };
}

// ---------------------------------------------------------------------------
// Cache LRU mémoire
// ---------------------------------------------------------------------------

class _LruCache {
  _LruCache(this.maxSize);

  final int maxSize;
  final _map = <String, _Entry>{};
  final _order = <String>[];

  _Entry? get(String key) {
    final e = _map[key];
    if (e == null) return null;
    _order..remove(key)..add(key);
    return e;
  }

  void put(String key, _Entry entry) {
    if (_map.containsKey(key)) {
      _order.remove(key);
    } else if (_map.length >= maxSize) {
      _map.remove(_order.removeAt(0));
    }
    _map[key] = entry;
    _order.add(key);
  }

  void remove(String key) {
    _map.remove(key);
    _order.remove(key);
  }

  void clear() {
    _map.clear();
    _order.clear();
  }
}

// ---------------------------------------------------------------------------
// ArtworkCache
// ---------------------------------------------------------------------------

/// Cache à deux niveaux pour les URLs de pochettes résolues.
///
/// Usage :
/// ```dart
/// final cache = ArtworkCache(
///   memoryCacheSize: 200,
///   diskCacheDuration: Duration(days: 7),
/// );
///
/// try {
///   final url = await cache.get(key); // null = pas d'artwork connu
/// } on CacheMiss {
///   // clé absente → résoudre via API
/// }
///
/// await cache.put(key, url); // url peut être null
/// ```
class ArtworkCache {
  ArtworkCache({
    required int memoryCacheSize,
    required Duration diskCacheDuration,
    String? diskCacheDir,
  })  : _lru = _LruCache(memoryCacheSize),
        _diskCacheDuration = diskCacheDuration,
        _diskCacheDir = diskCacheDir;

  final _LruCache _lru;
  final Duration _diskCacheDuration;
  final String? _diskCacheDir;

  Map<String, _Entry> _disk = {};
  bool _diskLoaded = false;
  File? _file;

  // ---------------------------------------------------------------------------
  // Clé de cache
  // ---------------------------------------------------------------------------

  /// Clé stable insensible à la casse à partir de artiste + titre.
  static String buildKey(String? artist, String? title) =>
      '${(artist ?? '').trim().toLowerCase()}|${(title ?? '').trim().toLowerCase()}';

  // ---------------------------------------------------------------------------
  // Lecture
  // ---------------------------------------------------------------------------

  /// Retourne l'URL mise en cache (peut être null si artwork absent connu).
  /// Lance [CacheMiss] si la clé n'est pas présente.
  Future<String?> get(String key) async {
    // Niveau 1 : mémoire
    final mem = _lru.get(key);
    if (mem != null) {
      if (mem.isExpired) {
        _lru.remove(key);
      } else {
        return mem.url;
      }
    }

    // Niveau 2 : disque
    await _loadDisk();
    final disk = _disk[key];
    if (disk != null) {
      if (disk.isExpired) {
        _disk.remove(key);
        await _saveDisk();
      } else {
        _lru.put(key, disk); // promotion en mémoire
        return disk.url;
      }
    }

    throw CacheMiss(key);
  }

  // ---------------------------------------------------------------------------
  // Écriture
  // ---------------------------------------------------------------------------

  Future<void> put(String key, String? url) async {
    // On ne met en cache que les résultats positifs.
    // Un résultat null peut venir d'une erreur réseau temporaire ou d'un
    // artiste absent des APIs à cet instant — on ne veut pas bloquer
    // les tentatives futures pour le même titre.
    if (url == null) return;
    final entry = _Entry(
      url: url,
      expiresAt: DateTime.now().add(_diskCacheDuration),
    );
    _lru.put(key, entry);
    await _loadDisk();
    _disk[key] = entry;
    await _saveDisk();
  }

  Future<void> invalidate(String key) async {
    _lru.remove(key);
    await _loadDisk();
    if (_disk.remove(key) != null) await _saveDisk();
  }

  Future<void> clear() async {
    _lru.clear();
    _disk.clear();
    final f = await _cacheFile();
    if (await f.exists()) await f.delete();
  }

  // ---------------------------------------------------------------------------
  // Persistance disque (JSON)
  // ---------------------------------------------------------------------------

  Future<void> _loadDisk() async {
    if (_diskLoaded) return;
    _diskLoaded = true;
    try {
      final f = await _cacheFile();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _disk = json.map(
            (k, v) => MapEntry(k, _Entry.fromJson(v as Map<String, dynamic>)),
      );
      // Purge des entrées expirées au chargement
      _disk.removeWhere((_, e) => e.isExpired);
    } catch (_) {
      _disk = {};
    }
  }

  Future<void> _saveDisk() async {
    try {
      final f = await _cacheFile();
      await f.writeAsString(
        jsonEncode(_disk.map((k, v) => MapEntry(k, v.toJson()))),
      );
    } catch (_) {
      // Erreur disque non-critique : le cache mémoire reste fonctionnel.
    }
  }

  Future<File> _cacheFile() async {
    if (_file != null) return _file!;
    final dir = _diskCacheDir ?? (await getApplicationCacheDirectory()).path;
    _file = File('$dir/radio_artwork_cache.json');
    return _file!;
  }
}

// ---------------------------------------------------------------------------
// Exception sentinelle
// ---------------------------------------------------------------------------

/// Levée par [ArtworkCache.get] quand la clé est absente du cache.
class CacheMiss implements Exception {
  const CacheMiss(this.key);
  final String key;

  @override
  String toString() => 'CacheMiss($key)';
}