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

/// La lecture est interrompue et le plugin retente — ce n'est ni un arrêt
/// voulu, ni une station cassée.
///
/// Émis quand la couche Dart n'arrive plus à alimenter le flux : coupure
/// réseau, serveur momentanément injoignable, aucun octet audio reçu depuis
/// le démarrage. Le lecteur ICY continue de se reconnecter indéfiniment tant
/// que la personne n'a pas arrêté la lecture — cet état est donc un avis
/// pour l'interface (« reconnexion en cours »), pas une fin de vie.
///
/// La sortie de cet état n'a pas besoin d'être signalée explicitement :
/// dès que les octets audio repartent, ExoPlayer réémet [PlayerPlaying].
class PlayerInterrupted extends PlayerState {}

/// Une erreur est survenue — [message] décrit le problème
class PlayerError extends PlayerState {
  final String message;
  PlayerError(this.message);
}
