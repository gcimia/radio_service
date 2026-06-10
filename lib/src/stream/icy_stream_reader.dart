/// IcyStreamReader — connexion HTTP côté Dart au flux radio.
///
/// Responsabilités :
///   1. Connexion HTTP au flux avec header Icy-MetaData:1
///   2. Lecture et parsing des headers ICY (Content-Type, icy-metaint…)
///   3. Séparation bytes audio / blocs de métadonnées ICY inline
///   4. Détection du format du StreamTitle et parsing en artist/title
///   5. Émission des métadonnées structurées via [onMetadata]
///   6. Transmission des bytes audio purs vers [AudioProxyServer]
///
/// Formats de StreamTitle supportés :
///   - Texte  : "ARTISTE - TITRE" (ICY standard)
///   - JSON   : {"artist":"X","title":"Y"} (radios modernes)
///   - XML    : <DNAS><SONGTITLE>…</SONGTITLE></DNAS> (SHOUTcast v2)
///   - Titre seul sans séparateur
///   - Séparateurs alternatifs : " / ", " | "
///
/// Ce composant est la seule source de métadonnées du plugin pour
/// les flux progressifs. Il fonctionne identiquement sur toutes
/// les plateformes (Android, iOS, Desktop) car il utilise dart:io pur.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Métadonnées structurées émises par IcyStreamReader
// ---------------------------------------------------------------------------

/// Métadonnées ICY complètement parsées — prêtes pour MetadataParser.
///
/// Les champs [artist] et [title] sont déjà séparés quel que soit
/// le format source (texte, JSON, XML). MetadataParser n'a plus
/// qu'à les fusionner avec les autres sources.
class IcyMetadata {
  const IcyMetadata({
    // Infos station (headers HTTP ICY)
    this.stationName,
    this.stationGenre,
    this.stationUrl,
    // Morceau en cours (bloc ICY inline)
    this.artist,
    this.title,
    this.streamUrl,
    // Infos flux
    this.contentType,
    this.bitrate,
    this.isHeader = false,
  });

  /// Nom de la station (icy-name)
  final String? stationName;

  /// Genre de la station (icy-genre)
  final String? stationGenre;

  /// URL de la station (icy-url)
  final String? stationUrl;

  /// Artiste du morceau en cours — déjà parsé depuis le StreamTitle
  final String? artist;

  /// Titre du morceau en cours — déjà parsé depuis le StreamTitle
  final String? title;

  /// URL du morceau (StreamUrl, rarement utilisé)
  final String? streamUrl;

  /// Type MIME du flux audio
  final String? contentType;

  /// Débit en kbps
  final int? bitrate;

  /// true = cet événement vient des headers de connexion (station name/genre)
  /// false = cet événement vient d'un bloc ICY inline (titre/artiste)
  final bool isHeader;

  /// Type de flux détecté depuis le Content-Type
  IcyStreamType get streamType {
    final ct = (contentType ?? '').toLowerCase();
    if (ct.contains('mpeg') || ct.contains('mp3')) return IcyStreamType.mp3;
    if (ct.contains('aac'))                        return IcyStreamType.aac;
    if (ct.contains('ogg'))                        return IcyStreamType.ogg;
    if (ct.contains('opus'))                       return IcyStreamType.opus;
    if (ct.contains('flac'))                       return IcyStreamType.flac;
    return IcyStreamType.unknown;
  }

  @override
  String toString() => 'IcyMetadata('
      'station:$stationName '
      'artist:$artist title:$title '
      'type:$streamType bitrate:${bitrate}kbps)';
}

/// Types de flux audio supportés.
enum IcyStreamType { mp3, aac, ogg, opus, flac, unknown }

// ---------------------------------------------------------------------------
// IcyStreamReader
// ---------------------------------------------------------------------------

class IcyStreamReader {
  IcyStreamReader({
    this.userAgent      = 'RadioService/1.0',
    this.connectTimeout = const Duration(seconds: 10),
    this.reconnectDelay = const Duration(seconds: 3),
    this.maxReconnects  = 5,
  });

  final String   userAgent;
  final Duration connectTimeout;
  final Duration reconnectDelay;
  final int      maxReconnects;

  // ── État interne ──────────────────────────────────────────────────────────

  String?                        _url;
  bool                           _running = false;
  int                            _metaint = 0;
  HttpClient?                    _client;
  StreamSubscription<List<int>>? _sub;

  // ── Callbacks ─────────────────────────────────────────────────────────────

  /// Appelé à la connexion (headers station) et à chaque bloc ICY inline.
  /// Les métadonnées sont déjà parsées — artist et title sont séparés.
  void Function(IcyMetadata metadata)? onMetadata;

  /// Chunk de bytes audio pur à transmettre au proxy.
  void Function(Uint8List bytes)? onAudioBytes;

  /// Erreur réseau ou de parsing.
  void Function(String error)? onError;

  /// Connexion établie.
  void Function()? onConnected;

  /// Lecture arrêtée.
  void Function()? onDisconnected;

  /// Toutes les tentatives de (re)connexion ont échoué — flux durablement
  /// indisponible. Distinct de [onError] (transitoire, on retente encore).
  void Function()? onUnavailable;

  // ── API publique ──────────────────────────────────────────────────────────

  Future<void> start(String url) async {
    await stop();
    _url     = url;
    _running = true;
    _connect(reconnectCount: 0);
  }

  Future<void> stop() async {
    _running = false;
    await _sub?.cancel();
    _sub = null;
    _client?.close(force: true);
    _client = null;
    onDisconnected?.call();
  }

  bool get isRunning => _running;

  // ── Connexion HTTP ────────────────────────────────────────────────────────

  Future<void> _connect({required int reconnectCount}) async {
    if (!_running || _url == null) return;

    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[IcyStreamReader] connexion → $_url');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    try {
      _client = HttpClient()..connectionTimeout = connectTimeout;

      final request = await _client!.getUrl(Uri.parse(_url!));
      request.headers
        ..set('Icy-MetaData', '1')
        ..set('User-Agent', userAgent)
        ..set('Accept', '*/*')
        ..set('Connection', 'keep-alive');

      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final headerMeta = _parseResponseHeaders(response);

      // ── DEBUG ────────────────────────────────────────────────────────────
      debugPrint('[IcyStreamReader] connecté — '
          'type:${headerMeta.contentType} '
          'metaint:$_metaint '
          'station:${headerMeta.stationName}');
      // ── FIN DEBUG ────────────────────────────────────────────────────────

      onConnected?.call();
      onMetadata?.call(headerMeta);

      await _readStream(response);

    } on Exception catch (e) {
      // ── DEBUG ────────────────────────────────────────────────────────────
      debugPrint('[IcyStreamReader] erreur: $e');
      // ── FIN DEBUG ────────────────────────────────────────────────────────

      onError?.call(e.toString());

      if (_running && reconnectCount < maxReconnects) {
        // ── DEBUG ──────────────────────────────────────────────────────────
        debugPrint('[IcyStreamReader] reconnexion dans '
            '${reconnectDelay.inSeconds}s '
            '(tentative ${reconnectCount + 1}/$maxReconnects)');
        // ── FIN DEBUG ──────────────────────────────────────────────────────
        await Future.delayed(reconnectDelay);
        _connect(reconnectCount: reconnectCount + 1);
      } else if (_running) {
        // Plus de tentatives — flux durablement indisponible.
        debugPrint('[IcyStreamReader] indisponible — $maxReconnects tentatives épuisées');
        onUnavailable?.call();
      }
    }
  }

  // ── Parsing des headers HTTP/ICY ──────────────────────────────────────────

  /// Corrige les chaînes encodées en double (Latin-1 puis UTF-8).
  /// Certains serveurs ICY encodent les headers en Latin-1, puis un proxy
  /// les réencode en UTF-8, produisant "gÃ©nÃ©ral" au lieu de "général".
  /// Les cas non récupérables (octets invalides remplacés par '?') sont
  /// retournés tels quels.
  String _fixEncoding(String s) {
    try {
      return utf8.decode(latin1.encode(s), allowMalformed: false);
    } catch (_) {
      return s;
    }
  }

  IcyMetadata _parseResponseHeaders(HttpClientResponse response) {
    String? stationName, stationGenre, stationUrl, contentType;
    int?    bitrate;

    response.headers.forEach((name, values) {
      final v = _fixEncoding(values.first);
      switch (name.toLowerCase()) {
        case 'icy-name':    stationName  = v;
        case 'icy-genre':   stationGenre = v;
        case 'icy-url':     stationUrl   = v;
        case 'icy-br':      bitrate      = int.tryParse(v);
        case 'icy-metaint': _metaint     = int.tryParse(v) ?? 0;
        case 'content-type':
          contentType = v.split(';').first.trim();
      }
    });

    return IcyMetadata(
      stationName:  stationName,
      stationGenre: stationGenre,
      stationUrl:   stationUrl,
      contentType:  contentType,
      bitrate:      bitrate,
      isHeader:     true,
    );
  }

  // ── Lecture du flux — séparation audio / blocs ICY ───────────────────────

  Future<void> _readStream(HttpClientResponse response) async {
    final buffer       = _ByteBuffer();
    int   bytesToAudio = _metaint;
    final completer    = Completer<void>();

    _sub = response.listen(
          (rawChunk) {
        if (!_running) return;
        final chunk = rawChunk is Uint8List
            ? rawChunk
            : Uint8List.fromList(rawChunk);
        buffer.add(chunk);

        // Flux sans métadonnées ICY — tout est audio
        if (_metaint == 0) {
          onAudioBytes?.call(buffer.consume(buffer.length));
          return;
        }

        // Traitement intercalé audio / blocs ICY
        while (buffer.length > 0) {
          if (bytesToAudio > 0) {
            final take = buffer.length < bytesToAudio
                ? buffer.length
                : bytesToAudio;
            onAudioBytes?.call(buffer.consume(take));
            bytesToAudio -= take;
          } else {
            if (buffer.length < 1) break;
            final metaLengthByte = buffer.peekByte();
            final metaLength     = metaLengthByte * 16;

            if (metaLength == 0) {
              buffer.consume(1);
              bytesToAudio = _metaint;
              continue;
            }

            if (buffer.length < 1 + metaLength) break;

            buffer.consume(1);
            final metaBytes = buffer.consume(metaLength);
            _parseIcyBlock(metaBytes);
            bytesToAudio = _metaint;
          }
        }
      },
      onDone: () {
        // ── DEBUG ──────────────────────────────────────────────────────────
        debugPrint('[IcyStreamReader] flux terminé');
        // ── FIN DEBUG ──────────────────────────────────────────────────────
        if (!completer.isCompleted) completer.complete();
      },
      onError: (e) {
        // ── DEBUG ──────────────────────────────────────────────────────────
        debugPrint('[IcyStreamReader] erreur flux: $e');
        // ── FIN DEBUG ──────────────────────────────────────────────────────
        if (!completer.isCompleted) completer.completeError(e as Object);
      },
      cancelOnError: true,
    );

    await completer.future;

    if (_running) {
      await Future.delayed(reconnectDelay);
      _connect(reconnectCount: 0);
    }
  }

  // ── Parsing d'un bloc ICY inline ─────────────────────────────────────────

  void _parseIcyBlock(Uint8List bytes) {
    // Décodage — ICY peut être UTF-8 ou Latin-1 selon le serveur.
    //
    // Stratégie :
    //   1. Tenter UTF-8 strict — si tous les octets sont UTF-8 valides,
    //      c'est du texte UTF-8 (norme ICY moderne).
    //   2. Si l'UTF-8 strict échoue → décoder en Latin-1 (ISO-8859-1).
    //      Latin-1 est l'encodage historique des flux ICY SHOUTcast.
    //      Chaque octet est un caractère valide en Latin-1, donc aucune perte.
    //
    // On n'utilise PAS allowMalformed:true car il remplace les octets
    // invalides UTF-8 par '?' ce qui détruit les accents Latin-1
    // (ex: É=0xC9 → '?' au lieu de 'É').
    String raw;
    try {
      raw = utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      // UTF-8 invalide → Latin-1 (toujours valide, aucune perte)
      raw = latin1.decode(bytes);
      // Tenter la correction Latin-1 → UTF-8 si le contenu semble
      // être du Latin-1 mal encodé (ex: "gÃ©nÃ©raliste" → "généraliste")
      try {
        final corrected = utf8.decode(latin1.encode(raw), allowMalformed: false);
        raw = corrected;
      } catch (_) {
        // Latin-1 pur — conserver tel quel
      }
    }

    // Suppression du padding nul
    raw = raw.replaceAll('\x00', '').trim();
    if (raw.isEmpty) return;

    // ── DEBUG ──────────────────────────────────────────────────────────────
    debugPrint('[IcyStreamReader] bloc ICY brut: "$raw"');
    // ── FIN DEBUG ──────────────────────────────────────────────────────────

    // Extraction du StreamTitle depuis le bloc ICY
    // Format : StreamTitle='CONTENU';[StreamUrl='...';]
    //
    // Problème : certains artistes/titres contiennent des apostrophes
    // (ex: KASSAV' - AN NOU TRIPE') qui ferment prématurément la regex
    // classique. On utilise [^;]* pour capturer tout jusqu'au ';' final
    // plutôt que de s'arrêter à la première apostrophe.
    String? rawTitle, streamUrl;

    final titleMatch = RegExp(
      r"StreamTitle='([^;]*)';",
      caseSensitive: false,
    ).firstMatch(raw);
    if (titleMatch != null) rawTitle = titleMatch.group(1);

    // Fallback si pas de ';' final — prend jusqu'à la fin de chaîne
    if (rawTitle == null) {
      final titleFallback = RegExp(
        r"StreamTitle='(.*?)'?\s*$",
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(raw);
      if (titleFallback != null) rawTitle = titleFallback.group(1);
    }

    final urlMatch = RegExp(
      r"StreamUrl='([^;]*)';",
      caseSensitive: false,
    ).firstMatch(raw);
    if (urlMatch != null) streamUrl = urlMatch.group(1)?.trim();
    if (streamUrl?.isEmpty ?? true) streamUrl = null;

    if (rawTitle == null) return;

    // ── DEBUG ──────────────────────────────────────────────────────────────
    debugPrint('[IcyStreamReader] StreamTitle brut: "$rawTitle"');
    // ── FIN DEBUG ──────────────────────────────────────────────────────────

    // Parsing du contenu — détection automatique du format
    final parsed = StreamTitleParser.parse(rawTitle);
    if (parsed == null) return;

    // ── DEBUG ──────────────────────────────────────────────────────────────
    debugPrint('[IcyStreamReader] parsé → '
        'artist:"${parsed.artist}" title:"${parsed.title}"');
    // ── FIN DEBUG ──────────────────────────────────────────────────────────

    onMetadata?.call(IcyMetadata(
      artist:    parsed.artist,
      title:     parsed.title,
      streamUrl: streamUrl,
      isHeader:  false,
    ));
  }
}

// ---------------------------------------------------------------------------
// StreamTitleParser — détection et parsing du format du StreamTitle
// ---------------------------------------------------------------------------

/// Résultat du parsing d'un StreamTitle.
class ParsedStreamTitle {
  const ParsedStreamTitle({this.artist, required this.title});
  final String? artist;
  final String  title;
}

/// Détecte automatiquement le format du StreamTitle et le parse.
///
/// Formats supportés dans l'ordre de détection :
///   1. JSON  : {"artist":"X","title":"Y"} ou {"t":"Y","a":"X"}
///   2. XML   : <DNAS><SONGTITLE>ARTISTE - TITRE</SONGTITLE></DNAS>
///              (SHOUTcast v2)
///   3. Texte : "ARTISTE - TITRE" (ICY standard)
///              "ARTISTE / TITRE", "ARTISTE | TITRE"
///              "ARTISTE - ARTISTE - TITRE" (nom répété par certaines radios)
///              "TITRE" seul
///
/// Post-traitement sur le nom d'artiste :
///   Suppression des suffixes parasites ajoutés par les radios :
///   "official", "officiel", "music", "tv", "channel"…
class StreamTitleParser {
  StreamTitleParser._();

  /// Suffixes parasites courants ajoutés après le nom d'artiste par les radios.
  /// Ex : "JEMYKA official" → "JEMYKA", "DJ Snake Official" → "DJ Snake"
  static final _artistSuffixPattern = RegExp(
    r'\s*\b(?:official|officiel|music|tv|channel|vevo|records|'
    r'prod|production|productions|entertainment|ent|'
    r'média|media|artiste|artist|groupe|group|band)\b\s*$',
    caseSensitive: false,
  );

  static String _removeArtistSuffix(String artist) =>
      artist.replaceAll(_artistSuffixPattern, '').trim();

  /// Retourne null si le StreamTitle est vide ou non-musical (liner, jingle…)
  static ParsedStreamTitle? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // Tentative JSON
    final json = _tryJson(trimmed);
    if (json != null) return _applyCleanup(json);

    // Tentative XML (SHOUTcast v2)
    final xml = _tryXml(trimmed);
    if (xml != null) return _applyCleanup(xml);

    // Texte — séparateurs multiples
    return _applyCleanup(_parseText(trimmed));
  }

  /// Applique le nettoyage post-parsing sur le nom d'artiste.
  static ParsedStreamTitle _applyCleanup(ParsedStreamTitle p) {
    if (p.artist == null) return p;
    final cleaned = _removeArtistSuffix(p.artist!);
    if (cleaned == p.artist) return p;
    return ParsedStreamTitle(artist: cleaned.isEmpty ? null : cleaned, title: p.title);
  }

  // ── JSON ─────────────────────────────────────────────────────────────────

  static ParsedStreamTitle? _tryJson(String raw) {
    if (!raw.startsWith('{')) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;

      // Clés standard
      final title  = _firstNonEmpty(map, ['title',  't', 'song', 'track', 'name']);
      final artist = _firstNonEmpty(map, ['artist', 'a', 'performer', 'creator']);

      if (title == null && artist == null) return null;

      // ── DEBUG ────────────────────────────────────────────────────────────
      debugPrint('[StreamTitleParser] format JSON détecté');
      // ── FIN DEBUG ────────────────────────────────────────────────────────

      // Si le JSON ne contient qu'un "title" et qu'il contient un séparateur,
      // on le parse comme du texte pour extraire l'artiste
      if (artist == null && title != null) {
        final fromText = _parseText(title);
        return fromText;
      }

      return ParsedStreamTitle(
        artist: artist?.isEmpty == true ? null : artist,
        title:  title ?? artist ?? raw,
      );
    } catch (_) {
      return null;
    }
  }

  static String? _firstNonEmpty(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final v = map[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  // ── XML (SHOUTcast v2) ────────────────────────────────────────────────────

  static ParsedStreamTitle? _tryXml(String raw) {
    if (!raw.contains('<')) return null;

    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[StreamTitleParser] format XML détecté');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    // Extraction par regex — on évite un vrai parser XML pour garder
    // dart:io pur sans dépendances
    String? extract(String tag) {
      final m = RegExp(
        '<$tag[^>]*>([^<]*)</$tag>',
        caseSensitive: false,
      ).firstMatch(raw);
      final v = m?.group(1)?.trim();
      return (v?.isNotEmpty ?? false) ? v : null;
    }

    // SHOUTcast v2 : <DNAS><SONGTITLE>ARTISTE - TITRE</SONGTITLE></DNAS>
    final songTitle = extract('SONGTITLE') ?? extract('title') ?? extract('song');
    final artist    = extract('ARTIST')    ?? extract('performer');

    if (songTitle == null && artist == null) return null;

    // Si on a un SONGTITLE sans ARTIST, on tente de le parser comme du texte
    if (artist == null && songTitle != null) {
      return _parseText(songTitle);
    }

    return ParsedStreamTitle(
      artist: artist,
      title:  songTitle ?? raw,
    );
  }

  // ── Texte — séparateurs multiples ────────────────────────────────────────

  /// Séparateurs testés dans l'ordre de priorité.
  static const _separators = [' - ', ' / ', ' | ', ' ~ '];

  static ParsedStreamTitle _parseText(String raw) {
    for (final sep in _separators) {
      final idx = raw.indexOf(sep);
      if (idx > 0 && idx < raw.length - sep.length) {
        final left  = raw.substring(0, idx).trim();
        final right = raw.substring(idx + sep.length).trim();

        if (left.isNotEmpty && right.isNotEmpty) {
          // Détecte le pattern "ARTISTE - ARTISTE - TITRE" :
          // certaines radios répètent le nom de l'artiste avant le titre.
          // On compare left avec le début de right (après normalisation).
          final leftNorm  = left.toLowerCase().replaceAll(_artistSuffixPattern, '').trim();
          final nextSepIdx = right.indexOf(sep);
          if (nextSepIdx > 0) {
            final rightFirst = right.substring(0, nextSepIdx).trim().toLowerCase();
            final rightRest  = right.substring(nextSepIdx + sep.length).trim();
            // Si left ≈ rightFirst → artiste répété, le vrai titre est rightRest
            if (rightRest.isNotEmpty &&
                (leftNorm == rightFirst ||
                    rightFirst.startsWith(leftNorm) ||
                    leftNorm.startsWith(rightFirst))) {
              return ParsedStreamTitle(artist: left, title: rightRest);
            }
          }

          return ParsedStreamTitle(artist: left, title: right);
        }
      }
    }

    // Aucun séparateur → titre seul, sans artiste
    return ParsedStreamTitle(artist: null, title: raw);
  }
}

// ---------------------------------------------------------------------------
// _ByteBuffer — buffer d'accumulation pour les chunks réseau
// ---------------------------------------------------------------------------

class _ByteBuffer {
  final _chunks = <Uint8List>[];
  int _length   = 0;

  int get length => _length;

  void add(Uint8List chunk) {
    _chunks.add(chunk);
    _length += chunk.length;
  }

  int peekByte() {
    for (final chunk in _chunks) {
      if (chunk.isNotEmpty) return chunk[0];
    }
    return 0;
  }

  Uint8List consume(int count) {
    if (count <= 0) return Uint8List(0);
    count = count.clamp(0, _length);

    final result = Uint8List(count);
    int  written = 0;

    while (written < count && _chunks.isNotEmpty) {
      final chunk = _chunks.first;
      final take  = (count - written).clamp(0, chunk.length);
      result.setRange(written, written + take, chunk, 0);
      written += take;

      if (take == chunk.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(chunk, take);
      }
    }

    _length -= written;
    return result;
  }
}