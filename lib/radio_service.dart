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

  final PlayerController    player;
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
  int _generation = 0;

  /// Dernier titre+artiste émis — déduplication ICY.
  String? _lastEmittedKey;
  String? _lastEmittedTitle;

  /// Nom et logo de la station — mémorisés dès le header ICY.
  /// Utilisés comme fallback dans la notification quand pas de méta musicale.
  String? _stationName;
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
  // erreurs détectées côté Dart (indisponibilité réseau, watchdog premier octet).
  // L'app n'écoute que ce flux — elle reçoit donc aussi bien un PlayerError
  // venant d'ExoPlayer qu'un PlayerError « radio indisponible » côté Dart.
  final _stateController = StreamController<PlayerState>.broadcast();
  StreamSubscription<PlayerState>? _nativeStateSub;

  // Watchdog « premier octet audio » — si aucun octet audio n'arrive après le
  // démarrage d'un flux ICY (serveur muet, lent, refus…), le flux est déclaré
  // indisponible au lieu de laisser le loader tourner à l'infini.
  static const _firstBytesTimeout = Duration(seconds: 15);
  Timer? _firstBytesTimer;

  // Évite d'émettre/traiter l'indisponibilité deux fois (watchdog + onUnavailable).
  bool _reportedUnavailable = false;

  // Empêche une double libération (dispose appelé plusieurs fois).
  bool _disposed = false;

  // ── Constructeur ───────────────────────────────────────────────────────────

  RadioService({
    ArtworkResolverConfig artworkConfig     = const ArtworkResolverConfig(),
    bool                  equalizerEnabled  = true,
    bool                  backgroundEnabled = true,
    bool                  autoResumeAfterFocusLoss = true,
  })  : player       = PlayerController(),
        equalizer    = EqualizerService(),
        notification = NotificationService(),
        background   = BackgroundService() {
    if (artworkConfig.enabled) {
      _artworkResolver = ArtworkResolver(config: artworkConfig);
      _artworkResolver!.clearCache();
    }
    // Envoie la configuration initiale au natif
    RadioServicePlatform.instance.configure(
      equalizerEnabled:  equalizerEnabled,
      backgroundEnabled: backgroundEnabled,
      autoResumeAfterFocusLoss: autoResumeAfterFocusLoss,
    );

    // Redirige les états natifs (ExoPlayer) vers le flux unifié.
    _nativeStateSub = player.stateStream.listen(
      _stateController.add,
      onError: (Object e) {
        if (!_stateController.isClosed) _stateController.add(PlayerError(e.toString()));
      },
    );
  }

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

    _lastEmittedKey   = null;
    _lastEmittedTitle = null;
    _generation       = 0;
    _stationName      = null;
    _stationLogoUrl       = null;
    _lastMusicArtworkData = null;
    _reportedUnavailable  = false;
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
      _proxy = AudioProxyServer();
      await _proxy!.start();

      // ── DEBUG ────────────────────────────────────────────────────────────
      debugPrint('[RadioService] proxy démarré: ${_proxy!.streamUrl}');
      // ── FIN DEBUG ────────────────────────────────────────────────────────

      // ── Démarrage du lecteur ICY ────────────────────────────────────────────
      _icyReader = IcyStreamReader();

      _icyReader!.onMetadata = (icyMeta) {
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

      _icyReader!.onAudioBytes = (bytes) {
        // Premier octet audio reçu → le flux répond, on désarme le watchdog.
        if (_firstBytesTimer != null) {
          _firstBytesTimer!.cancel();
          _firstBytesTimer = null;
        }
        _proxy?.pushAudioBytes(bytes);
        _proxyReceivingBytes = true;
        // Réarme le timer : un morceau long n'émet pas de StreamTitle pendant des minutes
        _resetSilenceTimer();
      };

      _icyReader!.onError = (error) {
        // ── DEBUG ──────────────────────────────────────────────────────────
        debugPrint('[RadioService] erreur flux: $error');
        // ── FIN DEBUG ──────────────────────────────────────────────────────
        // Erreur transitoire : IcyStreamReader retente encore. On ne signale
        // l'indisponibilité qu'à l'épuisement (onUnavailable) ou via le watchdog.
      };

      _icyReader!.onUnavailable = () {
        _reportUnavailable('Radio indisponible');
      };

      _icyReader!.onConnected = () {
        // Démarre le timer de détection stream silencieux dès la connexion établie.
        // Réinitialisé à chaque bloc ICY reçu. Déclenche isSilent si aucun
        // StreamTitle n'arrive dans [_silenceTimeout] et que le proxy reçoit des bytes.
        _proxyReceivingBytes = false;
        _resetSilenceTimer();
      };

      // Démarre la connexion au flux — non-bloquant
      _icyReader!.start(resolved.url);

      // Watchdog : si aucun octet audio n'arrive dans le délai imparti,
      // le flux est indisponible → on émet PlayerError au lieu de laisser
      // l'UI sur un loader infini. Désarmé au premier octet (onAudioBytes).
      _firstBytesTimer?.cancel();
      _firstBytesTimer = Timer(_firstBytesTimeout, () {
        if (!_proxyReceivingBytes) {
          _reportUnavailable('Radio indisponible (aucune donnée audio)');
        }
      });

      // ── Donne l'URL proxy à ExoPlayer ──────────────────────────────────────
      await RadioServicePlatform.instance.setUrl(
        _proxy!.streamUrl,
        stationName: _stationName,
        isHls:       false,
      );
    }

    // ── Polling REST optionnel ────────────────────────────────────────────────
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
        artistKey.isEmpty) return;

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

  // ── Indisponibilité ─────────────────────────────────────────────────────────

  /// Signale à l'UI que le flux est durablement indisponible et coupe la
  /// couche réseau Dart. Idempotent : déclenché soit par le watchdog
  /// (premier octet), soit par IcyStreamReader.onUnavailable.
  /// (Le nettoyage complet des ressources natives sera traité au groupe D.)
  void _reportUnavailable(String message) {
    if (_reportedUnavailable) return;
    _reportedUnavailable = true;

    _firstBytesTimer?.cancel();
    _firstBytesTimer = null;

    if (!_stateController.isClosed) {
      _stateController.add(PlayerError(message));
    }

    // Coupe le reader + le proxy pour ne plus consommer le réseau inutilement.
    // Fire-and-forget : on n'attend pas la fin de l'arrêt asynchrone.
    _stopStream();
  }

  // ── Arrêt du flux ──────────────────────────────────────────────────────────

  Future<void> _stopStream() async {
    // Arrêt des timers avant toute chose
    _stopSilenceTimer();
    _firstBytesTimer?.cancel();
    _firstBytesTimer = null;
    _proxyReceivingBytes = false;
    _poller?.stop();
    _poller = null;
    await _icyReader?.stop();
    _icyReader = null;
    await _proxy?.stop();
    _proxy = null;
  }

  // ── Nettoyage ──────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stopStream();
    await _nativeStateSub?.cancel();
    _nativeStateSub = null;
    // Libère les ressources natives (player, MediaSession, service, notification).
    await RadioServicePlatform.instance.release();
    await _metadataController.close();
    await _stateController.close();
  }
}