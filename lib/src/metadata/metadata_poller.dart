import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'metadata_mapping.dart';
import 'player_metadata.dart';

// Interroge périodiquement un endpoint REST pour récupérer
// les métadonnées du morceau en cours.
// Entièrement côté Dart — le code natif n'est pas impliqué.
//
// Fonctionnalités :
//   - Chemins JSON imbriqués via MetadataMapping  (ex: '8.current_song.title')
//   - Paramètre anti-cache automatique            (ex: ?ck=<timestamp>)
//   - Résolution des URLs relatives               (ex: /uploads/... → https://site.com/uploads/...)
class MetadataPoller {
  final String          metadataUrl;
  final MetadataMapping mapping;
  final Duration        interval;
  final void Function(PlayerMetadata) onMetadata;

  Timer?  _timer;
  String? _lastTitle;

  /// Base URL extraite de [metadataUrl] pour résoudre les URLs relatives.
  /// Ex: 'https://metis.fm/flux/metisfm/refresh.json' → 'https://metis.fm'
  late final String? _baseUrl;

  MetadataPoller({
    required this.metadataUrl,
    required this.mapping,
    required this.interval,
    required this.onMetadata,
  }) {
    final uri = Uri.tryParse(metadataUrl);
    _baseUrl = uri != null ? '${uri.scheme}://${uri.host}' : null;
  }

  /// Démarre le polling — premier appel immédiat, puis toutes les [interval]
  void start() {
    _poll();
    _timer = Timer.periodic(interval, (_) => _poll());
  }

  /// Arrête le polling proprement
  void stop() {
    _timer?.cancel();
    _timer     = null;
    _lastTitle = null;
  }

  Future<void> _poll() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);

      // Ajoute un paramètre anti-cache dynamique si l'URL en contient déjà un
      // sous la forme ?ck=... ou ?_=... ou ?t=...
      // Sinon, ajoute ?_t=<timestamp> pour forcer le rechargement.
      final uri = _buildUri();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('Cache-Control', 'no-cache');

      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        return;
      }

      final body = await response.transform(utf8.decoder).join();
      client.close();

      final json = jsonDecode(body) as Map<String, dynamic>;

      final title      = mapping.resolve(json, mapping.title);
      final artist     = mapping.resolve(json, mapping.artist);
      final artworkRaw = mapping.resolve(json, mapping.artworkUrl);
      final artworkUrl = _resolveUrl(artworkRaw);
      final startRaw   = mapping.resolve(json, mapping.startTime);

      // N'émet que si le titre a changé
      if (title == _lastTitle) return;
      _lastTitle = title;

      onMetadata(PlayerMetadata(
        title:         title,
        artist:        artist,
        artworkUrl:    artworkUrl,
        broadcastTime: _parseStartTime(startRaw),
        fromRest:      true,
      ));

    } catch (_) {
      // Erreur réseau ou JSON malformé — le prochain tick réessaiera
    }
  }

  /// Construit l'URI avec un paramètre anti-cache mis à jour à chaque appel.
  Uri _buildUri() {
    final base = Uri.parse(metadataUrl);
    final ts   = DateTime.now().millisecondsSinceEpoch.toString();

    // Remplace le paramètre anti-cache existant (ck, _t, t, _) ou en ajoute un
    final params = Map<String, String>.from(base.queryParameters);
    if (params.containsKey('ck'))  params['ck']  = ts;
    else if (params.containsKey('_t')) params['_t'] = ts;
    else if (params.containsKey('t'))  params['t']  = ts;
    else if (params.containsKey('_'))  params['_']  = ts;
    else params['_t'] = ts;  // ajoute si absent

    return base.replace(queryParameters: params);
  }

  /// Résout une URL potentiellement relative en URL absolue.
  /// Ex: '/uploads/media/metisfm/cover.png' → 'https://metis.fm/uploads/...'
  /// Les URLs déjà absolues (http/https) sont retournées telles quelles.
  String? _resolveUrl(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (_baseUrl == null) return raw;
    // URL relative : préfixe avec la base du site
    final path = raw.startsWith('/') ? raw : '/$raw';
    return '$_baseUrl$path';
  }

  // Parse l'heure de début dans les formats courants
  DateTime? _parseStartTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;

    // Timestamp Unix en secondes
    final unix = int.tryParse(raw);
    if (unix != null) {
      return DateTime.fromMillisecondsSinceEpoch(unix * 1000);
    }

    // ISO 8601
    try { return DateTime.parse(raw); } catch (_) {}

    // HH:mm ou HH:mm:ss — associé à la date d'aujourd'hui
    final parts = raw.split(':');
    if (parts.length >= 2) {
      final now  = DateTime.now();
      final h    = int.tryParse(parts[0]) ?? 0;
      final m    = int.tryParse(parts[1]) ?? 0;
      final s    = parts.length >= 3 ? (int.tryParse(parts[2]) ?? 0) : 0;
      return DateTime(now.year, now.month, now.day, h, m, s);
    }

    return null;
  }
}