import '../../radio_service_platform_interface.dart';
import 'player_position.dart';
import 'player_state.dart';

// Expose les commandes de lecture et les streams d'état/position.
// Délègue tout à RadioServicePlatform.instance —
// ne contient aucune logique métier.
class PlayerController {

  /// [onStop] est fourni par [RadioService] : arrêt de la couche réseau Dart
  /// (IcyStreamReader + AudioProxyServer) avant l'arrêt natif.
  ///
  /// Pourquoi ce détour : depuis que la reconnexion automatique n'a plus de
  /// plafond, « la personne n'a pas arrêté » est la seule condition qui
  /// l'arrête. Sans ce rappel, `player.stop()` ne coupait que le natif — le
  /// lecteur ICY aurait continué à se reconnecter et à consommer données et
  /// batterie après un arrêt volontaire. Les appelants existants ne changent
  /// pas : `service.player.stop()` garde exactement la même signature.
  // ignore: prefer_initializing_formals
  // Un paramètre nommé ne peut pas commencer par un souligné : `this._onStop`
  // est interdit. L'affectation explicite est donc la seule forme possible.
  PlayerController({Future<void> Function()? onStop}) : _onStop = onStop;

  final Future<void> Function()? _onStop;

  // ── Commandes ──────────────────────────────────────────────────────────────

  /// Démarre la lecture
  Future<void> play() => RadioServicePlatform.instance.play();

  /// Met en pause.
  ///
  /// La couche Dart reste active : le flux continue d'alimenter le proxy,
  /// ce qui permet une reprise immédiate. Seul [stop] coupe le réseau.
  Future<void> pause() => RadioServicePlatform.instance.pause();

  /// Arrête la lecture et libère le flux — côté Dart puis côté natif.
  Future<void> stop() async {
    await _onStop?.call();
    await RadioServicePlatform.instance.stop();
  }

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