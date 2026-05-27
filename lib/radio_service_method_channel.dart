import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'radio_service_platform_interface.dart';
import 'src/equalizer/equalizer_config.dart';
import 'src/player/player_position.dart';
import 'src/player/player_state.dart';

/// Implémentation MethodChannel — Android (et iOS à venir).
///
/// Dans la nouvelle architecture, ce canal gère uniquement :
///   - les commandes de lecture (play, pause, stop, setUrl…)
///   - les événements d'état (idle, buffering, playing, paused…)
///   - les événements de position (time-shift)
///   - la notification système (updateNativeMetadata)
///
/// Les métadonnées ICY ne passent PLUS par ce canal —
/// elles sont extraites côté Dart par IcyStreamReader.
class MethodChannelRadioService extends RadioServicePlatform {

  @visibleForTesting
  final methodChannel = const MethodChannel('radio_service');
  final _eventChannel = const EventChannel('radio_service/events');

  late final Stream<Map<String, dynamic>> _rawEvents =
      _eventChannel
          .receiveBroadcastStream()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .asBroadcastStream();

  // ── Streams ────────────────────────────────────────────────────────────────

  @override
  Stream<PlayerState> get stateStream => _rawEvents
      .where((e) => e['type'] == 'state')
      .map((e) => _toPlayerState(e['value'] as String));

  PlayerState _toPlayerState(String value) => switch (value) {
    'idle'      => PlayerIdle(),
    'buffering' => PlayerBuffering(),
    'playing'   => PlayerPlaying(),
    'paused'    => PlayerPaused(),
    'stopped'   => PlayerStopped(),
    final other => PlayerError('Unknown state: $other'),
  };

  @override
  Stream<PlayerPosition> get positionStream => _rawEvents
      .where((e) => e['type'] == 'position')
      .map((e) {
        final isLive = e['isLive'] as bool? ?? true;
        if (isLive) return LivePosition();
        return BufferedPosition(
          current:     Duration(milliseconds: e['currentMs']     as int),
          bufferStart: Duration(milliseconds: e['bufferStartMs'] as int),
          bufferEnd:   Duration(milliseconds: e['bufferEndMs']   as int),
        );
      });

  // ── Commandes ──────────────────────────────────────────────────────────────

  @override
  Future<void> configure({
    bool equalizerEnabled  = true,
    bool backgroundEnabled = true,
  }) =>
      methodChannel.invokeMethod('configure', {
        'equalizerEnabled':  equalizerEnabled,
        'backgroundEnabled': backgroundEnabled,
      });

  /// Transmet l'URL à ExoPlayer.
  ///   - Flux progressif : [proxyUrl] = URL du proxy local Dart (http://127.0.0.1:PORT/stream)
  ///   - Flux HLS        : [proxyUrl] = URL directe du manifest (.m3u8)
  @override
  Future<void> setUrl(
    String proxyUrl, {
    BufferConfig bufferConfig = const BufferConfig(),
    String? stationName,
    bool    isHls = false,
  }) =>
      methodChannel.invokeMethod('setUrl', {
        'url':   proxyUrl,
        'isHls': isHls,
        if (stationName != null) 'stationName': stationName,
      });

  @override
  Future<void> play() => methodChannel.invokeMethod('play');

  @override
  Future<void> pause() => methodChannel.invokeMethod('pause');

  @override
  Future<void> stop() => methodChannel.invokeMethod('stop');

  @override
  Future<void> setVolume(double volume) =>
      methodChannel.invokeMethod('setVolume', {'volume': volume});

  @override
  Future<void> seek(Duration position) =>
      methodChannel.invokeMethod('seek', {
        'positionMs': position.inMilliseconds,
      });

  @override
  Future<void> seekToLive() => methodChannel.invokeMethod('seekToLive');

  @override
  Future<void> updateNativeMetadata({
    String?    title,
    String?    artist,
    Uint8List? artworkBytes,
  }) =>
      methodChannel.invokeMethod('updateMetadata', {
        // title toujours envoyé — même vide — pour forcer le reset Android.
        // Sans ça, Android conserve l'ancien titre si on passe null.
        'title':      title ?? '',
        if (artist       != null) 'artist':       artist,
        // Bytes de la pochette téléchargée côté Dart — Kotlin ne refait pas
        // d'appel réseau, ce qui évite la fenêtre sans image dans la notification.
        if (artworkBytes != null) 'artworkBytes': artworkBytes,
      });

  @override
  Future<void> setEqualizer(EqualizerConfig config) =>
      methodChannel.invokeMethod('setEqualizer', config.toMap());

  @override
  Future<bool> isBackgroundServiceRunning() async {
    final result =
        await methodChannel.invokeMethod<bool>('isBackgroundServiceRunning');
    return result ?? false;
  }
}
