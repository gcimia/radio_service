import '../../radio_service_platform_interface.dart';

/// Rappels posés par [RadioService] pour piloter la couche réseau Dart
/// (IcyStreamReader + AudioProxyServer) depuis les commandes de lecture.
///
/// [PlayerController] ne délègue qu'au natif ; c'est [RadioService] qui détient
/// le lecteur ICY et le proxy. Ces rappels sont le seul chemin par lequel une
/// commande de lecture peut agir sur eux, sans changer la signature publique
/// des commandes : `service.player.pause()` s'appelle exactement pareil.
class PlayerStreamHooks {
  const PlayerStreamHooks({this.onStop, this.onPause, this.onBeforePlay});

  /// Arrêt explicite — coupe la couche réseau Dart avant l'arrêt natif.
  final Future<void> Function()? onStop;

  /// Pause explicite — relâche la source (voir [PlayerController.pause]).
  final Future<void> Function()? onPause;

  /// Avant la lecture — recharge la station si une pause l'avait relâchée.
  final Future<void> Function()? onBeforePlay;
}

// Expose les commandes de lecture et les streams d'état/position.
// Délègue tout à RadioServicePlatform.instance —
// ne contient aucune logique métier.
class PlayerController {

  // Un paramètre nommé ne peut pas commencer par un souligné : `this._hooks`
  // est interdit par le langage. L'affectation explicite est donc la seule
  // forme possible ici — l'ignore doit rester COLLÉ à la ligne visée, une
  // ligne de commentaire intercalée le rendrait inopérant.
  // ignore: prefer_initializing_formals
  PlayerController({PlayerStreamHooks? hooks}) : _hooks = hooks;

  final PlayerStreamHooks? _hooks;

  // ── Commandes ──────────────────────────────────────────────────────────────

  /// Démarre la lecture.
  ///
  /// Si une pause avait relâché la source, la station est rechargée d'abord —
  /// ce qui rejoint le direct plutôt que de reprendre là où on l'avait laissé.
  Future<void> play() async {
    await _hooks?.onBeforePlay?.call();
    await RadioServicePlatform.instance.play();
  }

  /// Met en pause — et relâche la source.
  ///
  /// La pause coupe la couche réseau Dart (lecteur ICY + proxy) en plus de
  /// mettre le lecteur natif en pause. C'était l'inverse jusqu'en v0.1.6 : le
  /// flux continuait d'alimenter un tampon que plus personne ne vidait, la
  /// liaison finissait par casser, et la reprise relançait la lecture sur une
  /// source morte — sans son et sans erreur.
  ///
  /// Un direct ne se reprend pas, il se rejoint : même quand la source tient,
  /// reprendre là où on s'était arrêté fait réécouter le passé le temps que le
  /// tampon se vide. La reconnexion de [play] n'est donc pas un coût, c'est le
  /// comportement juste.
  ///
  /// Sans effet sur les flux HLS, où ExoPlayer détient la connexion : la pause
  /// n'y consomme rien côté Dart et reste une pause native pure.
  ///
  /// Attention : seule une pause EXPLICITE passe par ici. Une pause provoquée
  /// par le focus audio (appel entrant, casque débranché) est déclenchée
  /// nativement et ne relâche pas la source — c'est voulu pour une
  /// interruption courte, mais une interruption longue laisse encore le
  /// problème entier. Voir le CHANGELOG de la v0.1.7.
  Future<void> pause() async {
    await _hooks?.onPause?.call();
    await RadioServicePlatform.instance.pause();
  }

  /// Arrête la lecture et libère le flux — côté Dart puis côté natif.
  Future<void> stop() async {
    await _hooks?.onStop?.call();
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