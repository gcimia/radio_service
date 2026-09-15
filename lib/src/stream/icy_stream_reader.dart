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
///   - XML    : `<DNAS><SONGTITLE>…</SONGTITLE></DNAS>` (SHOUTcast v2)
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
    this.userAgent        = 'RadioService/1.0',
    this.connectTimeout   = const Duration(seconds: 10),
    this.backoffDelays    = defaultBackoffDelays,
    this.interruptedAfter = const Duration(seconds: 15),
  });

  /// Recul entre deux tentatives : croissant, puis borné.
  /// La dernière valeur est répétée indéfiniment. On ne martèle pas un réseau
  /// absent, et on ne fait pas attendre une minute quand il revient au bout de
  /// trois secondes.
  static const List<Duration> defaultBackoffDelays = <Duration>[
    Duration(seconds:  1),
    Duration(seconds:  2),
    Duration(seconds:  4),
    Duration(seconds:  8),
    Duration(seconds: 15),
  ];

  final String         userAgent;
  final Duration       connectTimeout;
  final List<Duration> backoffDelays;

  /// Durée d'échec continu au bout de laquelle [onUnavailable] est appelé.
  /// Ce n'est pas un abandon : la boucle continue de retenter après.
  final Duration interruptedAfter;

  // ── État interne ──────────────────────────────────────────────────────────

  bool _running = false;

  /// Jeton de génération — incrémenté à chaque [start] et à chaque [stop].
  ///
  /// Chaque reprise asynchrone (fin de recul, callback de flux) compare le
  /// jeton qu'elle a capturé au démarrage de sa boucle à celui-ci avant
  /// d'agir. Un booléen partagé comme `_running` ne sait pas distinguer
  /// « je suis la bonne boucle » de « la boucle a redémarré sans moi » :
  /// une reprise réveillée juste après `start()` le voyait à `true` et
  /// repartait sur la nouvelle URL, en parallèle de la boucle légitime.
  int _generation = 0;

  StreamSubscription<List<int>>? _sub;
  HttpClient?                    _client;

  /// Attente de fin de flux en cours. Annuler l'abonnement ne déclenche NI
  /// onDone NI onError : sans ce point de sortie, un [stop] pendant la lecture
  /// laissait `_readStream` suspendu pour toujours — boucle bloquée, socket
  /// et abonnement jamais libérés.
  Completer<void>? _readCompleter;

  // Attente de recul en cours — [retryNow] la raccourcit.
  Timer?           _backoffTimer;
  Completer<void>? _backoffWaiter;
  bool             _immediateRetryRequested = false;

  // ── Callbacks ─────────────────────────────────────────────────────────────

  /// Appelé à la connexion (headers station) et à chaque bloc ICY inline.
  /// Les métadonnées sont déjà parsées — artist et title sont séparés.
  void Function(IcyMetadata metadata)? onMetadata;

  /// Chunk de bytes audio pur à transmettre au proxy.
  void Function(Uint8List bytes)? onAudioBytes;

  /// Erreur réseau ou de parsing — transitoire, la reconnexion suit.
  void Function(String error)? onError;

  /// Connexion établie.
  void Function()? onConnected;

  /// Lecture arrêtée.
  void Function()? onDisconnected;

  /// La (re)connexion échoue depuis [interruptedAfter] — le flux est
  /// durablement interrompu. Ce n'est PAS un abandon : la boucle continue
  /// de retenter tant que [stop] n'a pas été appelé. C'est un avis destiné
  /// à l'interface, appelé une seule fois par épisode d'interruption.
  void Function()? onUnavailable;

  // ── API publique ──────────────────────────────────────────────────────────

  Future<void> start(String url) async {
    await stop();
    // Après l'await : on prend un jeton neuf. Si un autre start() s'est
    // glissé entre-temps, c'est le dernier qui gagne et la boucle de l'autre
    // sortira à son prochain test de génération.
    final generation = ++_generation;
    _running = true;
    unawaited(_runLoop(generation, url));
  }

  Future<void> stop() async {
    // Le jeton est incrémenté AVANT tout await : toute reprise en vol
    // (recul, callback de flux) devient périmée dès cette ligne.
    _generation++;
    _running = false;

    // On détache avant d'attendre — les champs sont remis à null tout de
    // suite, puis on n'opère que sur les références locales. Un arrêt en vol
    // ne peut donc plus fermer la connexion qui l'a remplacé.
    final sub     = _sub;
    final client  = _client;
    final reading = _readCompleter;
    _sub           = null;
    _client        = null;
    _readCompleter = null;

    _cancelBackoff();
    if (reading != null && !reading.isCompleted) reading.complete();

    await sub?.cancel();
    client?.close(force: true);
    onDisconnected?.call();
  }

  /// Raccourcit le recul en cours et retente immédiatement.
  ///
  /// À appeler quand l'hôte SAIT que le réseau est revenu — il le sait avant
  /// nous. Le compteur de recul repart à zéro. Sans effet si la lecture est
  /// arrêtée. Si une tentative est déjà en vol, la demande est mémorisée et
  /// consommée juste après son échec, sans attendre le recul.
  void retryNow() {
    if (!_running) return;

    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[IcyStreamReader] retryNow — recul raccourci');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    _immediateRetryRequested = true;
    _cancelBackoff();
  }

  bool get isRunning => _running;

  // ── Boucle de connexion ───────────────────────────────────────────────────

  /// Boucle unique : une seule chaîne de connexion existe par génération.
  ///
  /// L'ancienne implémentation se rappelait elle-même (`_connect` →
  /// `Future.delayed` → `_connect`, et `_readStream` → `_connect`), ce qui
  /// laissait deux chaînes coexister dès qu'on changeait de station pendant
  /// un incident réseau. Une boucle `while` gardée par le jeton de génération
  /// supprime le problème par construction.
  Future<void> _runLoop(int generation, String url) async {
    int       attempt             = 0;     // échecs consécutifs sans octet reçu
    DateTime? interruptedSince;            // début de l'épisode en cours
    bool      interruptionReported = false;

    while (generation == _generation) {
      bool gotBytes = false;

      try {
        gotBytes = await _attempt(generation, url);
      } catch (e) {
        // Une génération plus récente signifie que l'échec vient de NOTRE
        // propre arrêt (client fermé de force) : ce n'est pas une erreur à
        // remonter à l'hôte.
        if (generation != _generation) return;
        // ── DEBUG ────────────────────────────────────────────────────────────
        debugPrint('[IcyStreamReader] erreur: $e');
        // ── FIN DEBUG ────────────────────────────────────────────────────────
        onError?.call(e.toString());
      }

      if (generation != _generation) return;

      if (gotBytes) {
        // La session a réellement diffusé de l'audio : qu'elle se soit
        // terminée proprement (onDone) ou en erreur (onError), c'est un
        // incident neuf. Le recul repart de zéro et l'épisode est clos.
        attempt              = 0;
        interruptedSince     = null;
        interruptionReported = false;
      } else {
        attempt++;
        final since = interruptedSince ??= DateTime.now();
        if (!interruptionReported &&
            DateTime.now().difference(since) >= interruptedAfter) {
          interruptionReported = true;
          // ── DEBUG ──────────────────────────────────────────────────────────
          debugPrint('[IcyStreamReader] interrompu depuis '
              '${interruptedAfter.inSeconds}s — on continue de retenter');
          // ── FIN DEBUG ──────────────────────────────────────────────────────
          onUnavailable?.call();
        }
      }

      // Demande d'essai immédiat arrivée pendant la tentative : on repart
      // sans attendre, compteur de recul remis à zéro.
      if (_immediateRetryRequested) {
        _immediateRetryRequested = false;
        attempt = 0;
        continue;
      }

      final delay = _backoffFor(attempt);

      // ── DEBUG ──────────────────────────────────────────────────────────────
      debugPrint('[IcyStreamReader] reconnexion dans ${delay.inSeconds}s '
          '(tentative ${attempt + 1})');
      // ── FIN DEBUG ──────────────────────────────────────────────────────────

      await _waitBackoff(delay);
      if (generation != _generation) return;

      if (_immediateRetryRequested) {
        _immediateRetryRequested = false;
        attempt = 0;
      }
    }
  }

  /// Recul applicable après [attempt] échecs consécutifs.
  /// `attempt == 0` (session réussie qui vient de se terminer) → première
  /// valeur de la table ; au-delà de la table, la dernière valeur est répétée.
  Duration _backoffFor(int attempt) {
    if (backoffDelays.isEmpty) return const Duration(seconds: 1);
    final index = (attempt - 1).clamp(0, backoffDelays.length - 1);
    return backoffDelays[index];
  }

  // ── Attente de recul interruptible ────────────────────────────────────────

  Future<void> _waitBackoff(Duration delay) {
    _cancelBackoff();
    final waiter = Completer<void>();
    _backoffWaiter = waiter;
    _backoffTimer  = Timer(delay, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    return waiter.future;
  }

  /// Réveille immédiatement l'attente en cours, s'il y en a une.
  /// La boucle réveillée retestera son jeton de génération avant d'agir.
  void _cancelBackoff() {
    _backoffTimer?.cancel();
    _backoffTimer = null;

    final waiter = _backoffWaiter;
    _backoffWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  // ── Une tentative de connexion ────────────────────────────────────────────

  /// Retourne true si la session a diffusé au moins un octet audio.
  /// Lève si la connexion elle-même a échoué (DNS, refus, HTTP ≠ 200).
  Future<bool> _attempt(int generation, String url) async {
    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[IcyStreamReader] connexion → $url');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    final client = HttpClient()..connectionTimeout = connectTimeout;

    // Chaque tentative créait un HttpClient sans fermer le précédent, et
    // stop() n'en fermait qu'un. On ferme celui de la tentative précédente.
    final previous = _client;
    _client = client;
    previous?.close(force: true);

    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers
        ..set('Icy-MetaData', '1')
        ..set('User-Agent',   userAgent)
        ..set('Accept',       '*/*')
        ..set('Connection',   'keep-alive');

      final response = await request.close();
      if (generation != _generation) return false;

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final (headerMeta, metaint) = _parseResponseHeaders(response);

      // ── DEBUG ──────────────────────────────────────────────────────────────
      debugPrint('[IcyStreamReader] connecté — '
          'type:${headerMeta.contentType} '
          'metaint:$metaint '
          'station:${headerMeta.stationName}');
      // ── FIN DEBUG ──────────────────────────────────────────────────────────

      onConnected?.call();
      onMetadata?.call(headerMeta);

      return await _readStream(generation, response, metaint);
    } finally {
      // On ne remet le champ à null que s'il pointe encore sur NOTRE client :
      // une génération plus récente a pu le remplacer entre-temps.
      if (identical(_client, client)) _client = null;
      client.close(force: true);
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

  /// Retourne les métadonnées de header ET le `metaint` de CETTE réponse.
  /// Le metaint était un champ d'instance : deux connexions concurrentes
  /// pouvaient se le disputer et désaligner la séparation audio/métadonnées.
  (IcyMetadata, int) _parseResponseHeaders(HttpClientResponse response) {
    String? stationName, stationGenre, stationUrl, contentType;
    int?    bitrate;
    int     metaint = 0;

    response.headers.forEach((name, values) {
      final v = _fixEncoding(values.first);
      switch (name.toLowerCase()) {
        case 'icy-name':    stationName  = v;
        case 'icy-genre':   stationGenre = v;
        case 'icy-url':     stationUrl   = v;
        case 'icy-br':      bitrate      = int.tryParse(v);
        case 'icy-metaint': metaint      = int.tryParse(v) ?? 0;
        case 'content-type':
          contentType = v.split(';').first.trim();
      }
    });

    return (
      IcyMetadata(
        stationName:  stationName,
        stationGenre: stationGenre,
        stationUrl:   stationUrl,
        contentType:  contentType,
        bitrate:      bitrate,
        isHeader:     true,
      ),
      metaint,
    );
  }

  // ── Lecture du flux — séparation audio / blocs ICY ───────────────────────

  /// Lit le flux jusqu'à sa fin ou son erreur. Ne lève jamais : une coupure
  /// en cours de flux et une fin de flux propre reçoivent le même traitement
  /// (voir la boucle), seule la valeur de retour distingue une session qui a
  /// diffusé de l'audio d'une session vide.
  Future<bool> _readStream(
    int                generation,
    HttpClientResponse response,
    int                metaint,
  ) async {
    final buffer       = _ByteBuffer();
    int   bytesToAudio = metaint;
    bool  gotBytes     = false;
    final completer    = Completer<void>();

    void emitAudio(Uint8List bytes) {
      if (bytes.isEmpty) return;
      gotBytes = true;
      onAudioBytes?.call(bytes);
    }

    final sub = response.listen(
      (rawChunk) {
        // Garde de génération, et non plus `_running` : un flux orphelin ne
        // doit pas pousser ses octets dans le proxy de la station suivante.
        if (generation != _generation) return;

        final chunk = rawChunk is Uint8List
            ? rawChunk
            : Uint8List.fromList(rawChunk);
        buffer.add(chunk);

        // Flux sans métadonnées ICY — tout est audio
        if (metaint == 0) {
          emitAudio(buffer.consume(buffer.length));
          return;
        }

        // Traitement intercalé audio / blocs ICY
        while (buffer.length > 0) {
          if (bytesToAudio > 0) {
            final take = buffer.length < bytesToAudio
                ? buffer.length
                : bytesToAudio;
            emitAudio(buffer.consume(take));
            bytesToAudio -= take;
          } else {
            if (buffer.length < 1) break;
            final metaLengthByte = buffer.peekByte();
            final metaLength     = metaLengthByte * 16;

            if (metaLength == 0) {
              buffer.consume(1);
              bytesToAudio = metaint;
              continue;
            }

            if (buffer.length < 1 + metaLength) break;

            buffer.consume(1);
            final metaBytes = buffer.consume(metaLength);
            _parseIcyBlock(metaBytes);
            bytesToAudio = metaint;
          }
        }
      },
      onDone: () {
        // ── DEBUG ──────────────────────────────────────────────────────────
        debugPrint('[IcyStreamReader] flux terminé');
        // ── FIN DEBUG ──────────────────────────────────────────────────────
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e) {
        // ── DEBUG ──────────────────────────────────────────────────────────
        debugPrint('[IcyStreamReader] erreur flux: $e');
        // ── FIN DEBUG ──────────────────────────────────────────────────────
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: true,
    );

    // Dernier contrôle avant de publier les champs : un stop() a pu passer
    // pendant l'établissement de la connexion. Publier ici écraserait le
    // détachement qu'il vient de faire, et la lecture resterait suspendue
    // pour toujours — abonnement et socket jamais libérés.
    if (generation != _generation) {
      await sub.cancel();
      return false;
    }

    _sub           = sub;
    _readCompleter = completer;

    try {
      await completer.future;
    } catch (e) {
      // Coupure en cours de flux : même traitement qu'une fin de flux, la
      // boucle retentera. On se contente d'informer l'hôte — sauf si la
      // coupure vient de notre propre arrêt.
      if (generation == _generation) onError?.call(e.toString());
    } finally {
      if (identical(_sub, sub))                 _sub           = null;
      if (identical(_readCompleter, completer)) _readCompleter = null;
      await sub.cancel();
    }

    return gotBytes;
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
///   2. XML   : `<DNAS><SONGTITLE>ARTISTE - TITRE</SONGTITLE></DNAS>`
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