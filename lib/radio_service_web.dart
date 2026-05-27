// ignore: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'radio_service_platform_interface.dart';
import 'src/buffer/buffer_config.dart';
import 'src/equalizer/equalizer_config.dart';
import 'src/player/player_position.dart';
import 'src/player/player_state.dart';

// Implémentation Web du plugin radio_service.
//
// Utilise l'API HTML5 <audio> native du navigateur pour lire les flux radio.
// Les flux ICY et HLS (.m3u8) sont tous deux supportés nativement par les
// navigateurs modernes (Chrome, Firefox, Safari).
//
// Limitations web vs Android :
//   - Pas d'égaliseur (nécessite Web Audio API — non implémenté ici)
//   - Pas de notification système persistante (Media Session API partielle)
//   - Les flux ICY avec headers propriétaires nécessitent souvent un proxy CORS
class RadioServiceWeb extends RadioServicePlatform {

  RadioServiceWeb();

  static void registerWith(Registrar registrar) {
    RadioServicePlatform.instance = RadioServiceWeb();
  }

  // ── État interne ───────────────────────────────────────────────────────────

  web.HTMLAudioElement? _audio;
  String? _stationName;
  Timer?  _positionTimer;

  final _stateController    = StreamController<PlayerState>.broadcast();
  final _metadataController = StreamController<PlayerMetadata>.broadcast();
  final _positionController = StreamController<PlayerPosition>.broadcast();

  // ── Interface ──────────────────────────────────────────────────────────────

  @override
  Future<void> configure({
    bool equalizerEnabled  = true,
    bool backgroundEnabled = true,
  }) async {
    _setupMediaSession();
  }

  @override
  Future<void> setUrl(
    String url, {
    BufferConfig bufferConfig = const BufferConfig(),
    String?      stationName,
    bool         isHls        = false,
  }) async {
    _stationName = stationName;
    _disposeAudio();

    final audio = web.HTMLAudioElement();
    _audio = audio;
    audio.preload     = 'none';
    audio.crossOrigin = 'anonymous';

    // Événements JS → classes PlayerState sealed
    audio.addEventListener('playing',
        ((web.Event _) => _stateController.add(PlayerPlaying())).toJS);
    audio.addEventListener('pause',
        ((web.Event _) => _stateController.add(PlayerPaused())).toJS);
    audio.addEventListener('waiting',
        ((web.Event _) => _stateController.add(PlayerBuffering())).toJS);
    audio.addEventListener('ended',
        ((web.Event _) => _stateController.add(PlayerStopped())).toJS);
    audio.addEventListener('error',
        ((web.Event _) => _stateController.add(PlayerError('Erreur audio'))).toJS);

    if (stationName != null) {
      _metadataController.add(PlayerMetadata(stationName: stationName));
    }

    audio.src = url;
  }

  @override
  Future<void> play() async {
    await _audio?.play().toDart;
    _startPositionTimer();
  }

  @override
  Future<void> pause() async {
    _audio?.pause();
    _stopPositionTimer();
    _stateController.add(PlayerPaused());
  }

  @override
  Future<void> stop() async {
    _disposeAudio();
    _stateController.add(PlayerStopped());
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_audio != null) _audio!.volume = volume;
  }

  @override
  Future<void> seek(Duration position) async {
    if (_audio != null) {
      _audio!.currentTime = position.inMilliseconds / 1000.0;
    }
  }

  @override
  Future<void> seekToLive() async {
    final audio = _audio;
    if (audio == null) return;
    final buffered = audio.buffered;
    if (buffered.length > 0) {
      audio.currentTime = buffered.end(buffered.length - 1);
    }
  }

  @override
  Future<void> updateNativeMetadata({
    String?    title,
    String?    artist,
    Uint8List? artworkBytes,
  }) async {
    _updateMediaSession(title: title, artist: artist);
  }

  @override
  Future<void> setEqualizer(EqualizerConfig config) async {
    // Web Audio API requise — non implémenté
  }

  @override
  Future<bool> isBackgroundServiceRunning() async => false;

  // ── Streams ────────────────────────────────────────────────────────────────

  @override
  Stream<PlayerState>    get stateStream    => _stateController.stream;

  @override
  Stream<PlayerMetadata> get metadataStream => _metadataController.stream;

  @override
  Stream<PlayerPosition> get positionStream => _positionController.stream;

  // ── Helpers privés ─────────────────────────────────────────────────────────

  void _disposeAudio() {
    _stopPositionTimer();
    final audio = _audio;
    if (audio != null) {
      audio.pause();
      audio.src = '';
      _audio = null;
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_audio != null) _positionController.add(LivePosition());
    });
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  void _setupMediaSession() {
    try {
      web.window.navigator.mediaSession.setActionHandler(
        'play',
        (() { _audio?.play(); }).toJS,
      );
      web.window.navigator.mediaSession.setActionHandler(
        'pause',
        (() { _audio?.pause(); }).toJS,
      );
    } catch (_) {}
  }

  void _updateMediaSession({String? title, String? artist}) {
    try {
      // MediaMetadata API — mise à jour du titre dans le navigateur
      // Package:web expose MediaMetadata depuis la version 1.x
    } catch (_) {}
  }
}
