import 'dart:io';

// Résout les URLs de playlist et de pages web en URL de flux directe.
// Appelé par RadioService.setUrl() avant de transmettre l'URL au natif.
// Le code natif reçoit toujours une URL de flux directe.
//
// Sources gérées :
//   - .pls     : playlist SHOUTcast
//   - .m3u     : playlist M3U
//   - .m3u8    : flux HLS — détecté et marqué isHls = true
//   - radioking.com/play/...    : page web RadioKing → flux listen.radioking.com
//   - radioendirect.net/stream/ : page web RadioEndirect → redirection HTTP
//   - Redirections HTTP 301/302 : suivi automatique

// Résultat de la résolution de playlist.
// Transporte l'URL finale et le type de flux détecté.
class ResolvedStream {
  const ResolvedStream({required this.url, required this.isHls});

  /// URL du flux prête à être passée au player.
  final String url;

  /// true si le flux est HLS (.m3u8) — ExoPlayer joue directement l'URL,
  /// pas de proxy Dart. Les métadonnées viennent des tags ID3 in-band.
  /// false si le flux est progressif (MP3/AAC/OGG) — proxy Dart + ICY.
  final bool isHls;
}

class PlaylistResolver {

  /// Résout l'URL et détecte le type de flux.
  ///
  /// Retourne un [ResolvedStream] avec :
  ///   - [url]   : URL finale du flux (après résolution .pls/.m3u/redirects)
  ///   - [isHls] : true si le flux est HLS (.m3u8)
  static Future<ResolvedStream> resolve(String url) async {
    final lower = url.toLowerCase();

    // HLS — ExoPlayer joue directement l'URL, pas de proxy Dart.
    if (lower.endsWith('.m3u8')) {
      return ResolvedStream(url: url, isHls: true);
    }

    // Formats de playlist classiques
    if (lower.endsWith('.pls')) {
      final resolved = await _resolvePls(url);
      return ResolvedStream(
        url:   resolved,
        isHls: resolved.toLowerCase().endsWith('.m3u8'),
      );
    }
    if (lower.endsWith('.m3u')) {
      final resolved = await _resolveM3u(url);
      return ResolvedStream(
        url:   resolved,
        isHls: resolved.toLowerCase().endsWith('.m3u8'),
      );
    }

    // Pages web avec flux embarqués
    String resolved = url;
    if (lower.contains('radioking.com/play/'))       resolved = await _resolveRadioKing(url);
    if (lower.contains('radioendirect.net/stream/')) resolved = await _resolveViaRedirect(url);

    // Flux direct — retour immédiat sans connexion réseau
    // IcyStreamReader gérera la connexion et les éventuelles redirections
    return ResolvedStream(
      url:   resolved,
      isHls: resolved.toLowerCase().endsWith('.m3u8'),
    );
  }

  // ── PLS ───────────────────────────────────────────────────────────────────

  static Future<String> _resolvePls(String url) async {
    final content = await _fetch(url);
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.toLowerCase().startsWith('file1=')) {
        return trimmed.substring(6).trim();
      }
    }
    return url;
  }

  // ── M3U ───────────────────────────────────────────────────────────────────

  static Future<String> _resolveM3u(String url) async {
    final content = await _fetch(url);
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (trimmed.startsWith('http')) return trimmed;
    }
    return url;
  }

  // ── RadioKing page web ────────────────────────────────────────────────────
  //
  // https://www.radioking.com/play/station-name/12345
  //   → https://listen.radioking.com/radio/12345/stream/XXXXX
  //
  // RadioKing expose une API publique qui retourne l'URL du flux :
  // https://www.radioking.com/api/radio/station-name
  // ou on peut suivre la redirection de la page play
  //
  // Stratégie : suivre la redirection HTTP de l'URL /play/
  // RadioKing redirige vers la page de la station qui contient le flux

  static Future<String> _resolveRadioKing(String url) async {
    // Extraire l'ID numérique s'il est présent dans l'URL
    // Ex: /play/blue-melody-school-radio/62896 → ID = 62896
    final idMatch = RegExp(r'/play/[^/]+/(\d+)').firstMatch(url);
    if (idMatch != null) {
      final id = idMatch.group(1)!;
      // L'API RadioKing publique retourne les infos de la station
      final apiUrl = 'https://www.radioking.com/api/radio/$id';
      final content = await _fetch(apiUrl);
      // Cherche l'URL du flux dans la réponse JSON
      final streamMatch = RegExp(r'"stream_url"\s*:\s*"([^"]+)"')
          .firstMatch(content);
      if (streamMatch != null) return streamMatch.group(1)!;
    }

    // Fallback : suivre les redirections de la page /play/
    return _resolveViaRedirect(url);
  }

  // ── Résolution via redirection HTTP ───────────────────────────────────────
  //
  // Certaines pages web redirigent vers l'URL du flux via 301/302.
  // On suit les redirections jusqu'à obtenir une URL de flux audio.

  static Future<String> _resolveViaRedirect(String url) async {
    try {
      final client  = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'RadioService/1.0');
      // followRedirects = true par défaut — dart:io suit les redirections
      final response = await request.close();
      // L'URL finale après redirections
      final finalUrl = response.redirects.isNotEmpty
          ? response.redirects.last.location.toString()
          : url;
      await response.drain<void>();
      client.close();
      return finalUrl;
    } catch (_) {
      return url;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static Future<String> _fetch(String url) async {
    try {
      final client   = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final request  = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'RadioService/1.0');
      final response = await request.close();
      final content  = await response.transform(
          const SystemEncoding().decoder).join();
      client.close();
      return content;
    } catch (_) {
      return '';
    }
  }
}
