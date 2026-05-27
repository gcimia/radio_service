// États possibles du lecteur radio.
// Sealed class — le compilateur force à traiter tous les cas
// dans un switch, ce qui évite les oublis.
sealed class PlayerState {}

/// Aucun flux chargé — état initial
class PlayerIdle extends PlayerState {}

/// Le flux est en cours de chargement / mise en mémoire tampon
class PlayerBuffering extends PlayerState {}

/// La lecture est active
class PlayerPlaying extends PlayerState {}

/// La lecture est en pause
class PlayerPaused extends PlayerState {}

/// La lecture s'est arrêtée normalement
class PlayerStopped extends PlayerState {}

/// Une erreur est survenue — [message] décrit le problème
class PlayerError extends PlayerState {
  final String message;
  PlayerError(this.message);
}