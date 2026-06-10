import 'dart:typed_data';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'radio_service_method_channel.dart';
import 'src/buffer/buffer_config.dart';
import 'src/equalizer/equalizer_config.dart';
import 'src/metadata/player_metadata.dart';
import 'src/metadata/metadata_mapping.dart';
import 'src/player/player_position.dart';
import 'src/player/player_state.dart';

export 'src/buffer/buffer_config.dart';
export 'src/equalizer/equalizer_config.dart';
export 'src/metadata/player_metadata.dart';
export 'src/metadata/metadata_mapping.dart';
export 'src/player/player_position.dart';
export 'src/player/player_state.dart';

/// Contrat que chaque plateforme doit respecter.
///
/// Dans la nouvelle architecture :
///   - setUrl() reçoit l'URL du proxy local Dart, pas l'URL radio
///   - metadataStream n'existe plus côté natif — les métadonnées
///     sont extraites par IcyStreamReader côté Dart
abstract class RadioServicePlatform extends PlatformInterface {

  RadioServicePlatform() : super(token: _token);

  static final Object _token = Object();
  static RadioServicePlatform _instance = MethodChannelRadioService();
  static RadioServicePlatform get instance => _instance;
  static set instance(RadioServicePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // ── Commandes de lecture ───────────────────────────────────────────────────

  /// Configuration initiale — appelée une seule fois depuis le constructeur
  /// [RadioService]. Transmet les flags d'activation des fonctionnalités
  /// optionnelles au natif avant toute lecture.
  Future<void> configure({
    bool equalizerEnabled  = true,
    bool backgroundEnabled = true,
    bool autoResumeAfterFocusLoss = true,
  }) => throw UnimplementedError('configure() not implemented.');

  /// Reçoit l'URL du proxy local Dart (http://127.0.0.1:PORT/stream).
  /// Le [bufferConfig] est conservé pour compatibilité mais ignoré
  /// côté natif dans la nouvelle architecture — ExoPlayer lit depuis
  /// le proxy local sans configuration de buffer spécifique.
  /// [url]         : URL du proxy local (flux progressif) ou URL HLS directe
  /// [stationName]  : Nom affiché dans la notification avant les métadonnées
  /// [isHls]        : true = ExoPlayer joue directement via HlsMediaSource
  ///                  false = ExoPlayer joue depuis le proxy Dart (ProgressiveMediaSource)
  Future<void> setUrl(
    String url, {
    BufferConfig bufferConfig = const BufferConfig(),
    String? stationName,
    bool    isHls = false,
  }) => throw UnimplementedError('setUrl() not implemented.');

  Future<void> play() =>
      throw UnimplementedError('play() not implemented.');

  Future<void> pause() =>
      throw UnimplementedError('pause() not implemented.');

  Future<void> stop() =>
      throw UnimplementedError('stop() not implemented.');

  /// Libération globale des ressources natives (player, MediaSession,
  /// foreground service, notification). À appeler à la fermeture définitive.
  Future<void> release() =>
      throw UnimplementedError('release() not implemented.');

  Future<void> setVolume(double volume) =>
      throw UnimplementedError('setVolume() not implemented.');

  // ── Time-shift ─────────────────────────────────────────────────────────────

  Future<void> seek(Duration position) =>
      throw UnimplementedError('seek() not implemented.');

  Future<void> seekToLive() =>
      throw UnimplementedError('seekToLive() not implemented.');

  // ── Notification et écran de verrouillage ─────────────────────────────────

  /// Met à jour la notification système et l'écran de verrouillage.
  /// Appelé par RadioService après résolution de l'artwork.
  /// Met à jour titre, artiste et pochette dans la notification Android.
  ///
  /// [artworkBytes] : bytes de l'image (JPEG/PNG) téléchargés par Dart.
  /// Dart gère le téléchargement — Kotlin reçoit les bytes directement,
  /// sans refaire d'appel réseau. Cela évite la fenêtre de vulnérabilité
  /// où la notification est reconstruite avant que l'image soit disponible.
  Future<void> updateNativeMetadata({
    String?    title,
    String?    artist,
    Uint8List? artworkBytes,
  }) => throw UnimplementedError('updateNativeMetadata() not implemented.');

  // ── Égaliseur ──────────────────────────────────────────────────────────────

  Future<void> setEqualizer(EqualizerConfig config) =>
      throw UnimplementedError('setEqualizer() not implemented.');

  // ── Background service ────────────────────────────────────────────────────

  Future<bool> isBackgroundServiceRunning() =>
      throw UnimplementedError('isBackgroundServiceRunning() not implemented.');

  // ── Streams d'événements ──────────────────────────────────────────────────

  /// État du lecteur natif (idle, buffering, playing, paused, stopped).
  Stream<PlayerState> get stateStream =>
      throw UnimplementedError('stateStream not implemented.');

  /// Position dans le buffer (time-shift).
  Stream<PlayerPosition> get positionStream =>
      throw UnimplementedError('positionStream not implemented.');

  // metadataStream intentionnellement absent —
  // les métadonnées sont gérées par IcyStreamReader côté Dart.
}
