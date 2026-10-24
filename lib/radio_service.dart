import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'radio_service_platform_interface.dart';
import 'src/artwork/artwork_resolver.dart';
import 'src/artwork/artwork_resolver_config.dart';
import 'src/background/background_service.dart';
import 'src/equalizer/equalizer_service.dart';
import 'src/metadata/metadata_parser.dart';
import 'src/metadata/metadata_poller.dart';
import 'src/metadata/playlist_resolver.dart';
export 'src/metadata/playlist_resolver.dart' show ResolvedStream;
import 'src/notification/notification_service.dart';
import 'src/player/player_controller.dart';
import 'src/stream/audio_proxy_server.dart';
import 'src/stream/icy_stream_reader.dart';

// Re-exports — l'app n'importe que radio_service.dart
export 'radio_service_platform_interface.dart';
export 'src/artwork/artwork_resolver_config.dart';
export 'src/equalizer/equalizer_config.dart';
export 'src/metadata/metadata_mapping.dart';
export 'src/metadata/player_metadata.dart';
export 'src/player/player_position.dart';
export 'src/player/player_state.dart';
export 'src/stream/icy_stream_reader.dart' show IcyStreamType;

/// Façade publique du plugin.
/// Point d'entrée unique pour l'application.
///
/// Architecture :
///   Dart (IcyStreamReader) → connexion HTTP, extraction ICY
///   Dart (AudioProxyServer) → bytes audio servis à ExoPlayer
///   ExoPlayer → lecture audio pure, aucune métadonnée remontée
class RadioService {

  // ── Sous-services publics ──────────────────────────────────────────────────

  /// Assigné dans le corps du constructeur — [PlayerController] reçoit un
  /// rappel vers [_stopStream], ce qu'une liste d'initialisation ne permet pas.
  late final PlayerController player;

  final EqualizerService    equalizer;
  final NotificationService notification;
  final BackgroundService   background;

  // ── État interne ───────────────────────────────────────────────────────────

  MetadataPoller?   _poller;
  ArtworkResolver?  _artworkResolver;
  IcyStreamReader?  _icyReader;
  AudioProxyServer? _proxy;
  final _metadataParser = MetadataParser();

  /// Compteur de génération — incrémenté à chaque nouveau titre musical.
  /// Sert uniquement à écarter une pochette résolue pour un titre périmé.
  int _generation = 0;

  /// Dernier appel à [setUrl], mémorisé pour pouvoir recharger la station
  /// après une pause qui a relâché la source. `null` tant qu'aucun flux n'a
  /// été chargé, et remis à `null` par [dispose].
  _StreamRequest? _lastRequest;

  /// Vrai entre une pause qui a relâché la source et la lecture qui la
  /// recharge. Seule une pause explicite le lève (voir [PlayerController]).
  bool _releasedByPause = false;

  /// Jeton de génération du FLUX — incrémenté à chaque [setUrl] et à chaque
  /// [_stopStream]. Distinct de [_generation] (qui suit les titres musicaux).
  ///
  /// Chaque closure et chaque timer armé pour un flux capture le jeton en
  /// vigueur et le compare avant d'agir. Sans lui, une closure survivant à un
  /// changement de station pousse ses octets — ou son verdict d'erreur — dans
  /// le flux de la station suivante.
  int _streamGeneration = 0;

  /// Dernier titre+artiste émis — déduplication ICY.
  String? _lastEmittedKey;
  String? _lastEmittedTitle;

  /// Nom et logo de la station — mémorisés dès le header ICY.
  /// Utilisés comme fallback dans la notification quand pas de méta musicale.
  String? _stationName;
  // Mémorisé depuis setUrl(stationLogoUrl:) mais pas encore consommé : le
  // fallback « logo station » dans la notification n'est pas implémenté.
  // Le paramètre public est conservé pour ne pas casser les appelants.
  // ignore: unused_field
  String? _stationLogoUrl;
  /// Bytes de la dernière pochette musicale — fallback pendant jingles/pubs.
  Uint8List? _lastMusicArtworkData;


  // ── Téléchargement image côté Dart ───────────────────────────────────────────

  /// Dart télécharge la pochette et renvoie les bytes à Kotlin.
  /// Évite que Kotlin fasse un appel réseau asynchrone pendant lequel
  /// la notification peut être reconstruite sans image.
  Future<Uint8List?> _downloadImageBytes(String url) async {
    try {
      final client   = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request  = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) { client.close(); return null; }
      final builder  = BytesBuilder();
      await for (final chunk in response) { builder.add(chunk); }
      client.close();
      return builder.takeBytes();
    } catch (_) {
      return null;
    }
  }

  // ── Détection stream silencieux ────────────────────────────────────────────
  // Distingue une coupure réseau (pas de bytes reçus) d'un stream sans contenu
  // (bytes reçus mais aucun StreamTitle ICY depuis longtemps).
  //
  // Logique :
  //   _proxyReceivingBytes = false → coupure réseau → timer ignoré
  //   _proxyReceivingBytes = true  → stream silencieux → émet isSilent: true
  static const _silenceTimeout    = Duration(seconds: 45);
  Timer?   _silenceTimer;
  bool     _proxyReceivingBytes   = false;

  final _metadataController = StreamController<PlayerMetadata>.broadcast();

  // ── Flux d'état unifié ──────────────────────────────────────────────────────
  // Fusionne les états natifs (ExoPlayer via le canal d'événements) et les
  // états détectés côté Dart (interruption réseau, watchdog premier octet).
  // L'app n'écoute que ce flux — elle reçoit donc aussi bien un PlayerError
  // venant d'ExoPlayer qu'un PlayerInterrupted produit par la couche Dart.
  final _stateController = StreamController<PlayerState>.broadcast();
  StreamSubscription<PlayerState>? _nativeStateSub;

  // Watchdog « premier octet audio » — si aucun octet audio n'arrive après le
  // démarrage d'un flux ICY (serveur muet, lent, refus…), le flux est déclaré
  // interrompu au lieu de laisser le loader tourner à l'infini. Avis pour
  // l'interface uniquement : la reconnexion continue.
  static const _firstBytesTimeout = Duration(seconds: 15);
  Timer? _firstBytesTimer;

  // Évite d'émettre l'interruption deux fois (watchdog + onUnavailable).
  // Remis à false dès que des octets audio repartent : un épisode suivant
  // doit pouvoir être signalé à son tour.
  bool _reportedInterrupted = false;

  // Empêche une double libération (dispose appelé plusieurs fois).
  bool _disposed = false;

  // ── Constructeur ───────────────────────────────────────────────────────────

  RadioService({
    ArtworkResolverConfig artworkConfig     = const ArtworkResolverConfig(),
    bool                  equalizerEnabled  = true,
    bool                  backgroundEnabled = true,
    bool                  autoResumeAfterFocusLoss = true,
  })  : equalizer    = EqualizerService(),
        notification = NotificationService(),
        background   = BackgroundService() {
    // L'arrêt explicite coupe aussi la couche réseau Dart : c'est la seule
    // chose qui met fin à la reconnexion automatique, désormais sans plafond.
    player = PlayerController(
      hooks: PlayerStreamHooks(
        onStop:       _stopOnRequest,
        onPause:      _releaseForPause,
        onBeforePlay: _restoreAfterPause,
      ),
    );

    if (artworkConfig.enabled) {
      _artworkResolver = ArtworkResolver(config: artworkConfig);
      _artworkResolver!.clearCache();
    }
    // Envoie la configuration initiale au natif.
    // L'appel n'est pas attendu, donc son échec deviendrait une erreur
    // asynchrone non capturée : sur une plateforme sans implémentation native
    // (iOS, desktop), le simple fait de construire RadioService faisait
    // remonter une MissingPluginException hors de toute pile d'appel.
    unawaited(
      RadioServicePlatform.instance.configure(
        equalizerEnabled:  equalizerEnabled,
        backgroundEnabled: backgroundEnabled,
        autoResumeAfterFocusLoss: autoResumeAfterFocusLoss,
      ).catchError((Object e) {
        debugPrint('[RadioService] configure() a échoué : $e');
      }),
    );

    // Redirige les états natifs (ExoPlayer) vers le flux unifié.
    _nativeStateSub = player.stateStream.listen(
      _stateController.add,
      onError: (Object e) {
        if (!_stateController.isClosed) _stateController.add(PlayerError(e.toString()));
      },
    );
  }

  // ── Plateformes ────────────────────────────────────────────────────────────

  /// Plateformes réellement implémentées.
  ///
  /// Seul Android dispose d'une implémentation native. iOS, macOS, Windows,
  /// Linux et le web n'ont que le squelette généré par Flutter — le plugin ne
  /// les déclare donc plus dans son `pubspec.yaml`.
  ///
  /// Toute la couche Dart (connexion ICY, proxy, métadonnées, pochettes,
  /// reconnexion) est en revanche indépendante de la plateforme : c'est le
  /// moteur de lecture et l'intégration système qui manquent.
  static bool get isPlatformSupported => Platform.isAndroid;

  static String get _unsupportedMessage =>
      'radio_service ne gère que Android pour le moment '
      '(plateforme courante : ${Platform.operatingSystem}).';

  // ── Commandes principales ──────────────────────────────────────────────────

  /// Charge un flux radio et démarre la lecture.
  ///
  /// [url]             : URL du flux (MP3, AAC, OGG — HLS à venir)
  /// [metadataUrl]     : endpoint REST optionnel pour les métadonnées
  /// [metadataMapping] : comment lire les champs dans la réponse JSON
  /// [pollingInterval] : fréquence de polling REST (défaut : 10 secondes)
  Future<void> setUrl(
      String url, {
        String?          stationName,      // Nom affiché dans la notification avant l'ICY
        String?          stationLogoUrl,   // Logo station — fallback si pas de pochette
        String?          metadataUrl,
        MetadataMapping? metadataMapping,
        Duration         pollingInterval = const Duration(seconds: 10),
      }) async {
    // Arrêt de tout ce qui était en cours
    await _stopStream();

    // Plateforme sans moteur natif : on le dit à l'UI au lieu de laisser
    // remonter une MissingPluginException depuis les profondeurs du canal.
    if (!isPlatformSupported) {
      debugPrint('[RadioService] $_unsupportedMessage');
      if (!_stateController.isClosed) {
        _stateController.add(PlayerError(_unsupportedMessage));
      }
      return;
    }

    // Jeton de CE flux. Il est pris APRÈS l'arrêt : si deux setUrl se
    // chevauchent, chacun prend un jeton neuf et seul le dernier reste
    // légitime — l'autre sortira à son prochain test de génération plutôt
    // que d'écraser les champs partagés.
    final generation = ++_streamGeneration;

    _lastEmittedKey   = null;
    _lastEmittedTitle = null;
    _generation       = 0;
    _stationName      = null;
    _stationLogoUrl       = null;
    _lastMusicArtworkData = null;
    _reportedInterrupted  = false;
    _metadataParser.reset();

    // Effacement du cache artwork à chaque changement de radio
    _artworkResolver?.clearCache();

    // Émission immédiate d'un PlayerMetadata vide pour réinitialiser l'UI.
    // Sans ça, les métadonnées de la radio précédente restent affichées
    // si la nouvelle radio ne produit pas de StreamTitle (ex: Guadeloupe 1ère).
    _metadataController.add(PlayerMetadata(stationName: _stationName));

    // Reset de la notification — efface titre/artiste/pochette de la radio précédente.
    _updateNotification(title: null, artist: null);

    // Nom de station initial pour la notification — en attendant le header ICY.
    // Priorité : stationName fourni par le dev > domaine extrait de l'URL.
    // Ex sans stationName : 'https://guadeloupe.ice.infomaniak.ch/...'
    //                      → 'guadeloupe.ice.infomaniak.ch' (fallback)
    if (stationName?.isNotEmpty ?? false) {
      _stationName = stationName;
    } else {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.host.isNotEmpty) _stationName = uri.host;
    }
    if (stationLogoUrl?.isNotEmpty ?? false) {
      _stationLogoUrl = stationLogoUrl;
    }
    _updateNotification(title: _stationName, artist: null);

    // Résolution des playlists (.pls, .m3u) et détection HLS
    final resolved = await PlaylistResolver.resolve(url);

    // Premier point de suspension : un autre setUrl a pu passer entre-temps.
    if (generation != _streamGeneration) return;

    // Mémorise la demande pour pouvoir la rejouer après une pause. On la pose
    // APRÈS la résolution de playlist : `isHls` décide si la pause relâche
    // quoi que ce soit, et une playlist .pls peut pointer ailleurs à chaque
    // résolution — c'est l'URL d'origine qu'il faut rejouer, pas la résolue.
    _lastRequest = _StreamRequest(
      url:             url,
      stationName:     stationName,
      stationLogoUrl:  stationLogoUrl,
      metadataUrl:     metadataUrl,
      metadataMapping: metadataMapping,
      pollingInterval: pollingInterval,
      isHls:           resolved.isHls,
    );
    _releasedByPause = false;

    if (resolved.isHls) {
      // ── Chemin HLS ─────────────────────────────────────────────────────────
      // ExoPlayer joue directement l'URL HLS via HlsMediaSource.
      // Dart ne gère pas la connexion — pas de proxy, pas d'IcyStreamReader.
      // Les métadonnées arrivent via les tags ID3 in-band des segments .ts/.aac,
      // remontés par MetadataExtractor.kt via le canal d'événements natif.
      //
      // ── DEBUG ────────────────────────────────────────────────────────────
      debugPrint('[RadioService] flux HLS détecté → ExoPlayer joue directement: ${resolved.url}');
      // ── FIN DEBUG ────────────────────────────────────────────────────────
      await RadioServicePlatform.instance.setUrl(
        resolved.url,
        stationName: _stationName,
        isHls:       true,
      );
    } else {
      // ── Chemin ICY progressif ───────────────────────────────────────────────
      // Dart gère la connexion HTTP, extrait les métadonnées ICY,
      // et passe les bytes audio via le proxy local à ExoPlayer.

      // ── Démarrage du proxy audio ────────────────────────────────────────────
      // Le proxy et le lecteur sont manipulés par des variables LOCALES,
      // capturées dans les closures. Celles-ci lisaient auparavant le champ
      // `_proxy` : un lecteur périmé pouvait donc pousser ses octets dans le
      // proxy de la station suivante, ou pousser dans une référence déjà
      // remise à null par un arrêt en vol — ExoPlayer n'était alors plus
      // alimenté et rendait un « source error » sur une station saine.
      final proxy = AudioProxyServer();
      await proxy.start();

      // Deuxième point de suspension — même garde.
      if (generation != _streamGeneration) {
        await proxy.stop();
        return;
      }
      _proxy = proxy;

      // ── DEBUG ────────────────────────────────────────────────────────────
      debugPrint('[RadioService] proxy démarré: ${proxy.streamUrl}');
      // ── FIN DEBUG ────────────────────────────────────────────────────────

      // ── Démarrage du lecteur ICY ────────────────────────────────────────────
      final reader = IcyStreamReader();
      _icyReader = reader;

      reader.onMetadata = (icyMeta) {
        if (generation != _streamGeneration) return;
        if (icyMeta.isHeader) {
          // Headers de connexion (station name, genre…)
          final data = <String, dynamic>{
            'type':   'metadata',
            'source': 'icy_header',
          };
          if (icyMeta.stationName  != null) data['stationName']  = icyMeta.stationName;
          if (icyMeta.stationGenre != null) data['stationGenre'] = icyMeta.stationGenre;
          if (icyMeta.stationUrl   != null) data['stationUrl']   = icyMeta.stationUrl;
          if (data.length > 2) {
            final parsed = _metadataParser.parse(data);
            if (parsed != null) _onMetadata(parsed);
          }
        } else {
          // Bloc ICY inline — artist et title déjà parsés par StreamTitleParser.
          // Chaque StreamTitle reçu réarme le timer de silence.
          _resetSilenceTimer();
          if (icyMeta.title?.isNotEmpty ?? false) {
            final event = <String, dynamic>{
              'type':   'metadata',
              'source': 'icy_info',
              'title':  icyMeta.title,
              if (icyMeta.artist?.isNotEmpty ?? false) 'artist': icyMeta.artist,
            };
            final parsed = _metadataParser.parse(event);
            if (parsed != null) _onMetadata(parsed);
          }
        }
      };

      reader.onAudioBytes = (bytes) {
        if (generation != _streamGeneration) return;
        // Premier octet audio reçu → le flux répond, on désarme le watchdog.
        if (_firstBytesTimer != null) {
          _firstBytesTimer!.cancel();
          _firstBytesTimer = null;
        }
        // Des octets repartent → l'épisode d'interruption est clos et un
        // épisode suivant pourra de nouveau être signalé. La sortie de
        // PlayerInterrupted n'a pas besoin d'être émise ici : ExoPlayer
        // réémet PlayerPlaying dès qu'il redécode.
        _reportedInterrupted = false;
        // Instance locale, jamais le champ.
        proxy.pushAudioBytes(bytes);
        _proxyReceivingBytes = true;
        // Réarme le timer : un morceau long n'émet pas de StreamTitle pendant des minutes
        _resetSilenceTimer();
      };

      reader.onError = (error) {
        if (generation != _streamGeneration) return;
        // ── DEBUG ──────────────────────────────────────────────────────────
        debugPrint('[RadioService] erreur flux: $error');
        // ── FIN DEBUG ──────────────────────────────────────────────────────
        // Erreur transitoire : IcyStreamReader retente encore. On ne signale
        // l'interruption qu'après un échec durable (onUnavailable) ou via le
        // watchdog « premier octet ».
        //
        // Le proxy ne reçoit plus rien : sans cette ligne, le détecteur de
        // silence voyait _proxyReceivingBytes encore à true et annonçait à
        // l'UI un « flux silencieux » alors qu'il s'agit d'une coupure.
        _proxyReceivingBytes = false;
      };

      reader.onUnavailable = () {
        if (generation != _streamGeneration) return;
        _reportInterrupted('reconnexions infructueuses');
      };

      reader.onConnected = () {
        if (generation != _streamGeneration) return;
        // Démarre le timer de détection stream silencieux dès la connexion établie.
        // Réinitialisé à chaque bloc ICY reçu. Déclenche isSilent si aucun
        // StreamTitle n'arrive dans [_silenceTimeout] et que le proxy reçoit des bytes.
        _proxyReceivingBytes = false;
        _resetSilenceTimer();
      };

      // Démarre la connexion au flux — non-bloquant
      reader.start(resolved.url);

      // Watchdog : si aucun octet audio n'arrive dans le délai imparti, on
      // émet PlayerInterrupted au lieu de laisser l'UI sur un loader infini.
      // Désarmé au premier octet (onAudioBytes). Il ne coupe plus rien — le
      // lecteur continue de retenter derrière.
      _firstBytesTimer?.cancel();
      _firstBytesTimer = Timer(_firstBytesTimeout, () {
        if (generation != _streamGeneration) return;
        if (!_proxyReceivingBytes) {
          _reportInterrupted(
              'aucune donnée audio après ${_firstBytesTimeout.inSeconds}s');
        }
      });

      // ── Donne l'URL proxy à ExoPlayer ──────────────────────────────────────
      await RadioServicePlatform.instance.setUrl(
        proxy.streamUrl,
        stationName: _stationName,
        isHls:       false,
      );
    }

    // ── Polling REST optionnel ────────────────────────────────────────────────
    // Dernier point de suspension (setUrl natif) — même garde.
    if (generation != _streamGeneration) return;

    if (metadataUrl != null) {
      _poller = MetadataPoller(
        metadataUrl: metadataUrl,
        // Si aucun mapping fourni, on utilise les noms de champs les plus
        // courants dans les APIs radio : title/artist/artworkUrl
        mapping: metadataMapping ?? const MetadataMapping(
          title:      'title',
          artist:     'artist',
          artworkUrl: 'artworkUrl',
        ),
        interval:   pollingInterval,
        onMetadata: _onMetadata,
      );
      _poller!.start();
    }
  }

  // ── Streams unifiés ────────────────────────────────────────────────────────

  Stream<PlayerState>    get stateStream    => _stateController.stream;
  Stream<PlayerMetadata> get metadataStream => _metadataController.stream;
  Stream<PlayerPosition> get positionStream => player.positionStream;

  // ── Gestion interne ────────────────────────────────────────────────────────

  /// Pattern titre — mots-clés non-musicaux dans le titre (sans artiste).
  static final _nonMusicTitlePattern = RegExp(
    r'(^|\b)('
    // Publicité
    r'pub\b|publicite|page\s+pub|coupure\s+pub|pause\s+pub|sequence\s+pub|'
    r'spot\b|annonce\b|'
    // Habillage / identité
    r'liner|jingle|generique|indicatif|habillage|'
    // Émissions / infos
    r'flash\s+info|flash\s+actu|meteo\b|la\s+meteo|'
    r'decrochage|decro\b|top\s+h|horaire|'
    r'billboard|speakerine?|'
    // Promotions
    r'promo\b|stores\b|'
    // Émissions typiques radio caribéenne (nom d'émission sans artiste)
    r'bonjour\s+\w+|bonne\s+nuit|bonne\s+soiree|'
    r'reveil\b|matin\s+\w+|soiree\s+\w+|nuit\s+\w+|'
    r'frequences?\b|direct\s+\w+'
    r')(\b|$)',
    caseSensitive: false,
  );

  /// Pattern artiste — l'artiste entier est un label de pub/habillage.
  /// Plus strict que le pattern titre pour éviter les faux positifs
  /// sur des noms d'artistes comme "DJ SPOT" ou "DJ PUB MIX".
  static final _nonMusicArtistPattern = RegExp(
    r'^(pub|publicite|page\s+pub|coupure\s+pub|pause\s+pub|sequence\s+pub|'
    r'annonce|liner|jingle|generique|indicatif|habillage|speakerine?)$',
    caseSensitive: false,
  );

  /// Retourne true si le contenu est clairement non-musical :
  ///   1. Titre vide ou composé uniquement de tirets/espaces
  ///   2. L'artiste entier est un label de pub/habillage (ex: "PAGE PUB")
  ///   3. Le titre contient un mot-clé non-musical, sans artiste musical
  bool _isNonMusical(PlayerMetadata m) {
    final title  = m.title?.trim()  ?? '';
    final artist = m.artist?.trim() ?? '';

    // Cas 1 — titre vide ou tirets seuls
    if (title.isEmpty || RegExp(r'^[-–—\s]+$').hasMatch(title)) return true;

    // Cas 2 — artiste = label de pub entier (strict)
    // ex: "PAGE PUB" → non-musical / "DJ SPOT" → musical
    if (artist.isNotEmpty && _nonMusicArtistPattern.hasMatch(artist)) return true;

    // Cas 3 — artiste présent et non-pub → on fait confiance → musical
    if (artist.isNotEmpty) return false;

    // Cas 4 — pas d'artiste → vérifie le titre (pattern large)
    return _nonMusicTitlePattern.hasMatch(title);
  }

  Future<void> _onMetadata(PlayerMetadata metadata) async {
    // Mémoriser le nom de station dès le header ICY.
    // On ignore les valeurs qui ressemblent à un mount point (commence par '/')
    // ou qui sont trop courtes pour être un vrai nom (ex: '/guadeloupe-128').
    final icyName = metadata.stationName?.trim() ?? '';
    if (icyName.isNotEmpty && !icyName.startsWith('/')) {
      _stationName = icyName;
    }

    if (_isNonMusical(metadata)) {
      _generation++;
      // En non-musical, mettre la notification et l'UI à jour avec le nom de station
      // pour ne pas laisser l'ancienne méta musicale affichée.
      _metadataController.add(PlayerMetadata(stationName: _stationName));
      _updateNotification(title: _stationName, artist: null);
      return;
    }

    final titleKey  = metadata.title?.trim()  ?? '';
    final artistKey = metadata.artist?.trim() ?? '';
    final emitKey   = '$artistKey|$titleKey';

    if (emitKey == _lastEmittedKey) return;
    if (titleKey.isNotEmpty &&
        titleKey == _lastEmittedTitle &&
        artistKey.isEmpty) {
      return;
    }

    _lastEmittedKey   = emitKey;
    _lastEmittedTitle = titleKey;

    final generation = ++_generation;

    // Émission immédiate titre + artiste vers l'UI
    _metadataController.add(metadata);

    // Mise à jour notification immédiate — artwork pas encore résolu.
    // _lastMusicArtworkData garde la pochette précédente en fond.
    _updateNotification(
      title:  metadata.title ?? _stationName,
      artist: metadata.artist,
    );

    // Résolution artwork
    final hasContent = (metadata.artist?.trim().isNotEmpty ?? false) ||
        (metadata.title?.trim().isNotEmpty  ?? false);
    if (_artworkResolver != null &&
        metadata.artworkData == null &&
        metadata.artworkUrl  == null &&
        hasContent) {
      final url = await _artworkResolver!.resolve(
        artist: metadata.artist,
        title:  metadata.title,
      );

      if (_generation != generation) {
        // ── DEBUG ──────────────────────────────────────────────────────────
        debugPrint('[RadioService] artwork ignoré — titre périmé '
            '(génération courante:$_generation attendue:$generation)');
        // ── FIN DEBUG ──────────────────────────────────────────────────────
        return;
      }
      if (url == null) {
        // ── DEBUG ──────────────────────────────────────────────────────────
        debugPrint('[RadioService] artwork non trouvé pour '
            '"${metadata.artist}" / "${metadata.title}"');
        // ── FIN DEBUG ──────────────────────────────────────────────────────
        return;
      }

      // Dart télécharge les bytes — Kotlin les reçoit directement sans appel réseau
      final bytes = await _downloadImageBytes(url);

      // Deuxième suspension : le titre a pu changer pendant le téléchargement.
      // Sans ce test, la pochette d'un titre périmé s'installait comme
      // fallback dans _lastMusicArtworkData et dans la notification.
      if (_generation != generation) return;

      if (bytes != null) _lastMusicArtworkData = bytes;

      // Émission vers l'UI avec l'URL (l'UI charge l'image elle-même)
      _metadataController.add(metadata.copyWith(artworkUrl: url));

      // Notification avec les bytes prêts — pas de téléchargement asynchrone Kotlin
      _updateNotification(
        title:       metadata.title ?? _stationName,
        artist:      metadata.artist,
        artworkBytes: bytes ?? _lastMusicArtworkData,
      );
    }
  }

  /// Met à jour la notification système avec les fallbacks appropriés :
  ///   titre   → titre morceau  ?? nom station ?? ''
  ///   artiste → artiste        ?? ''
  ///   image   → pochette       ?? logo station ?? (logo appli géré côté Android)
  void _updateNotification({
    String?    title,
    String?    artist,
    Uint8List? artworkBytes,
  }) {
    notification.update(
      title:        title?.isNotEmpty  == true ? title  : _stationName,
      artist:       artist?.isNotEmpty == true ? artist : null,
      artworkBytes: artworkBytes ?? _lastMusicArtworkData,
    );
  }


  // ── Détection stream silencieux ────────────────────────────────────────────

  /// Réarme le timer de silence — appelé à chaque StreamTitle ICY reçu
  /// et à la connexion initiale.
  void _resetSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(_silenceTimeout, _onSilenceDetected);
  }

  /// Arrête le timer — appelé à l'arrêt du flux.
  void _stopSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  /// Déclenché quand aucun StreamTitle ICY n'est reçu depuis [_silenceTimeout].
  /// Ne signale le silence que si le proxy reçoit bien des bytes —
  /// si _proxyReceivingBytes = false, c'est une coupure réseau, pas un silence.
  void _onSilenceDetected() {
    if (!_proxyReceivingBytes) {
      // Pas de bytes du tout → coupure réseau → IcyStreamReader se reconnecte
      // → on ne fait rien, le timer sera réarmé à la reconnexion
      return;
    }
    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[RadioService] stream silencieux détecté (45s sans StreamTitle ICY)');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    // Émet un PlayerMetadata avec isSilent = true pour informer l'UI.
    // L'UI peut afficher une bannière ou un SnackBar.
    _metadataController.add(PlayerMetadata(
      stationName: _stationName,
      isSilent:    true,
    ));
  }

  // ── Interruption ────────────────────────────────────────────────────────────

  /// Signale à l'UI que le flux est interrompu — et rien d'autre.
  ///
  /// Déclenché soit par le watchdog « premier octet », soit par
  /// `IcyStreamReader.onUnavailable`. Idempotent par épisode : le drapeau est
  /// remis à false dès que des octets audio repartent.
  ///
  /// Cette méthode NE COUPE PLUS le flux. L'ancienne version appelait
  /// `_stopStream()` en fire-and-forget, dont les écritures de champs
  /// s'exécutaient après ses `await` : l'arrêt reprenait la main une fois la
  /// station suivante démarrée et arrêtait SON proxy. ExoPlayer n'était plus
  /// alimenté et rendait un « source error » sur une station parfaitement
  /// saine — « la source error bloque les autres radios ».
  ///
  /// Et sur le fond : une coupure réseau n'est pas une fin de vie. Le lecteur
  /// retente indéfiniment tant que la personne n'a pas arrêté ; couper ici
  /// garantissait au contraire que rien ne repartirait jamais tout seul.
  void _reportInterrupted(String reason) {
    if (_reportedInterrupted) return;
    _reportedInterrupted = true;

    _firstBytesTimer?.cancel();
    _firstBytesTimer = null;

    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[RadioService] flux interrompu — $reason '
        '(reconnexion automatique en cours)');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    if (!_stateController.isClosed) {
      _stateController.add(PlayerInterrupted());
    }
  }

  // ── Pause, reprise, arrêt — cycle de vie de la source ──────────────────────

  /// Arrêt explicite : coupe la couche réseau Dart et oublie la station.
  Future<void> _stopOnRequest() async {
    _lastRequest     = null;
    _releasedByPause = false;
    await _stopStream();
  }

  /// Pause explicite : relâche la source.
  ///
  /// Jusqu'en v0.1.6 la pause ne coupait rien, « pour permettre une reprise
  /// immédiate ». Le lecteur ICY continuait donc de tirer sur la station et de
  /// remplir un tampon que plus personne ne vidait ; au bout d'un moment la
  /// liaison cassait, et la reprise relançait la lecture sur une source morte —
  /// ni son, ni erreur, ni mouvement à l'écran.
  ///
  /// Sans effet sur un flux HLS : ExoPlayer y détient la connexion, la pause
  /// ne consomme rien côté Dart et une reconnexion serait gratuite.
  Future<void> _releaseForPause() async {
    final request = _lastRequest;
    if (request == null || request.isHls) return;
    if (_releasedByPause) return;

    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[RadioService] pause — source relâchée, rechargée à la reprise');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    _releasedByPause = true;
    // _stopStream incrémente le jeton de génération : la coupure qui suit ne
    // peut donc pas être annoncée comme une interruption. Une pause ne doit
    // jamais ressembler à une perte de réseau.
    await _stopStream();
  }

  /// Avant la lecture : recharge la station si une pause l'avait relâchée.
  ///
  /// Recharger plutôt que reprendre est le comportement juste pour un direct.
  /// Même si la source tenait encore, reprendre là où on s'était arrêté ferait
  /// réécouter le passé le temps que le tampon se vide — dix minutes de pause,
  /// dix minutes de retard.
  Future<void> _restoreAfterPause() async {
    if (!_releasedByPause) return;
    final request = _lastRequest;
    _releasedByPause = false;
    if (request == null) return;

    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[RadioService] reprise — rechargement de la station');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    await setUrl(
      request.url,
      stationName:     request.stationName,
      stationLogoUrl:  request.stationLogoUrl,
      metadataUrl:     request.metadataUrl,
      metadataMapping: request.metadataMapping,
      pollingInterval: request.pollingInterval,
    );
  }

  // ── Reprise forcée ──────────────────────────────────────────────────────────

  /// Raccourcit le recul en cours et retente immédiatement.
  ///
  /// À appeler quand l'hôte SAIT que le réseau est revenu — il le sait avant
  /// nous. Le partage de responsabilité est le suivant : le plugin possède la
  /// connexion, donc il possède la reconnexion et retente seul, indéfiniment ;
  /// l'application possède la connaissance du réseau, donc elle peut
  /// RACCOURCIR l'attente. Elle ne la remplace pas — si [retryNow] n'est
  /// jamais appelé, la lecture repart quand même, simplement plus tard.
  ///
  /// Sans effet sur les flux HLS (ExoPlayer y gère sa propre connexion) et
  /// sans effet si aucun flux n'est chargé.
  Future<void> retryNow() async {
    _icyReader?.retryNow();
  }

  // ── Arrêt du flux ──────────────────────────────────────────────────────────

  /// Coupe la couche réseau Dart : polling REST, lecteur ICY, proxy audio.
  ///
  /// La règle appliquée ici vaut pour les trois cycles de vie asynchrones du
  /// plugin : **on détache avant d'attendre, et on n'écrit jamais un champ
  /// partagé après un `await`.**
  ///
  /// L'ancienne version écrivait `_icyReader = null` et `_proxy = null` APRÈS
  /// ses `await`. Un arrêt parti en vol pendant un incident réseau reprenait
  /// la main une fois la station suivante démarrée, relisait les champs — qui
  /// pointaient alors sur le proxy et le lecteur NEUFS — et les arrêtait.
  Future<void> _stopStream() async {
    // Incrémenté avant tout await : toute closure et tout timer restés en vol
    // deviennent périmés dès cette ligne.
    _streamGeneration++;

    // Arrêt des timers avant toute chose
    _stopSilenceTimer();
    _firstBytesTimer?.cancel();
    _firstBytesTimer = null;
    _proxyReceivingBytes = false;

    // Détachement : les champs sont remis à null AVANT le premier await,
    // puis on n'opère plus que sur les références locales.
    final poller = _poller;
    final reader = _icyReader;
    final proxy  = _proxy;
    _poller    = null;
    _icyReader = null;
    _proxy     = null;

    poller?.stop();
    await reader?.stop();
    await proxy?.stop();
  }

  // ── Nettoyage ──────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _lastRequest     = null;
    _releasedByPause = false;
    await _stopStream();
    await _nativeStateSub?.cancel();
    _nativeStateSub = null;
    // Libère les ressources natives (player, MediaSession, service, notification).
    await RadioServicePlatform.instance.release();
    await _metadataController.close();
    await _stateController.close();
  }
}

/// Arguments d'un appel à [RadioService.setUrl], mémorisés pour pouvoir
/// recharger la station après une pause qui a relâché la source.
///
/// On garde l'URL D'ORIGINE, pas celle résolue : une playlist (.pls, .m3u) peut
/// désigner un autre serveur à chaque résolution, et c'est la demande initiale
/// qu'il faut rejouer. [isHls] est en revanche le résultat de la résolution —
/// c'est lui qui décide si une pause a quelque chose à relâcher.
class _StreamRequest {
  const _StreamRequest({
    required this.url,
    required this.stationName,
    required this.stationLogoUrl,
    required this.metadataUrl,
    required this.metadataMapping,
    required this.pollingInterval,
    required this.isHls,
  });

  final String           url;
  final String?          stationName;
  final String?          stationLogoUrl;
  final String?          metadataUrl;
  final MetadataMapping? metadataMapping;
  final Duration         pollingInterval;
  final bool             isHls;
}
