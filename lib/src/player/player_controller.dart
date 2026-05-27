import '../../radio_service_platform_interface.dart';
import 'player_position.dart';
import 'player_state.dart';

// Expose les commandes de lecture et les streams d'état/position.
// Délègue tout à RadioServicePlatform.instance —
// ne contient aucune logique métier.
class PlayerController {

  // ── Commandes ──────────────────────────────────────────────────────────────

  /// Démarre la lecture
  Future<void> play() => RadioServicePlatform.instance.play();

  /// Met en pause
  Future<void> pause() => RadioServicePlatform.instance.pause();

  /// Arrête la lecture et libère le flux
  Future<void> stop() => RadioServicePlatform.instance.stop();

  /// Ajuste le volume — valeur entre 0.0 (muet) et 1.0 (maximum)
  Future<void> setVolume(double volume) =>
      RadioServicePlatform.instance.setVolume(volume.clamp(0.0, 1.0));

  /// Déplace la position dans le buffer (time-shift)
  Future<void> seek(Duration position) =>
      RadioServicePlatform.instance.seek(position);

  /// Retour immédiat au live
  Future<void> seekToLive() =>
      RadioServicePlatform.instance.seekToLive();

  // ── Streams ────────────────────────────────────────────────────────────────

  /// Changements d'état du lecteur — écouter pour mettre à jour l'UI
  Stream<PlayerState> get stateStream =>
      RadioServicePlatform.instance.stateStream;

  /// Position dans le buffer — émet chaque seconde
  Stream<PlayerPosition> get positionStream =>
      RadioServicePlatform.instance.positionStream;
}