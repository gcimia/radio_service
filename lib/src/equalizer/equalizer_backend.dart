// Qui pilote réellement l'égalisation sur cet appareil.
//
// Classe scellée, comme PlayerState : le compilateur force à traiter tous les
// cas, et le jour où un membre s'ajoute, l'échec se produit à la compilation
// chez l'hôte plutôt qu'à l'écran chez la personne.
//
// ── Pourquoi ce choix existe ───────────────────────────────────────────────
//
// Beaucoup d'appareils appliquent déjà leur propre traitement en sortie, avec
// leur propre égaliseur — souvent meilleur que le nôtre : davantage de bandes,
// accordé pour ce haut-parleur précis, et réglé avec la marge qui convient.
//
// Empiler le nôtre par-dessus donne deux égaliseurs en série, et surtout : le
// bundle d'effets standard d'Android retranche une marge proportionnelle au
// gain positif demandé, pour éviter l'écrêtage. Un preset qui monte les basses
// de 6 dB voit donc l'ensemble baisser d'autant — la courbe est juste, le
// niveau a chuté, et un renforcement s'entend comme une atténuation.
//
// Plutôt que de lutter contre cette marge, on délègue quand l'appareil sait
// faire mieux. C'est le routage que décrit cette classe.
sealed class EqualizerBackend {}

/// L'hôte a demandé la délégation (`preferSystemEqualizer: true`) ET l'appareil
/// expose un panneau d'égaliseur : le plugin lui laisse la main et n'attache
/// aucun effet `Equalizer` à la session.
///
/// Ce n'est jamais le défaut, et ce n'est jamais décidé à l'exécution : c'est
/// un choix d'hôte, pris une fois à la construction. Le bouton « Égaliseur »
/// de l'application ouvre alors [EqualizerService.openSystemPanel] au lieu de
/// ses curseurs — **un seul bouton dans les deux cas**, le mécanisme derrière
/// ne regarde pas la personne qui appuie.
///
/// `apply()` et `reset()` n'ont aucun effet dans ce mode, et le réglage
/// appartient au téléphone : le plugin ne peut ni le lire, ni le mémoriser,
/// ni le restaurer.
class EqualizerSystem extends EqualizerBackend {}

/// L'égaliseur 5 bandes du plugin est attaché à la session et `apply()` le
/// pilote. C'est le cas par défaut, et le seul qui fonctionne identiquement
/// sur tous les appareils.
class EqualizerPlugin extends EqualizerBackend {}

/// Aucune égalisation disponible — [reason] dit pourquoi.
///
/// Les cas connus : `equalizerEnabled: false` à la construction, plateforme
/// sans implémentation native, ou refus du système d'instancier l'effet (ce
/// qui arrive sur certains appareils quand une autre application tient déjà
/// la session).
class EqualizerUnavailable extends EqualizerBackend {
  EqualizerUnavailable(this.reason);
  final String reason;

  @override
  String toString() => 'EqualizerUnavailable($reason)';
}
