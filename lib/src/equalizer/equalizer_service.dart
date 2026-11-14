import '../../radio_service_platform_interface.dart';

// Applique une configuration d'égaliseur au lecteur audio.
// Peut être appelé à tout moment, même pendant la lecture.
//
// Attention au routage : sur un appareil qui expose son propre panneau
// d'égaliseur, le plugin lui laisse la main et [apply] n'a aucun effet.
// Interroger [backend] avant de décider quoi afficher — voir [EqualizerBackend].
class EqualizerService {

  /// Qui pilote l'égalisation sur cet appareil.
  ///
  /// Résolu une seule fois puis mémorisé : la réponse dépend de ce que le
  /// système expose, ce qui ne change pas en cours de vie du processus.
  /// À lire APRÈS la construction de [RadioService], qui déclenche le
  /// `configure` natif où la décision est prise.
  Future<EqualizerBackend> get backend =>
      _backend ??= RadioServicePlatform.instance.getEqualizerBackend();

  Future<EqualizerBackend>? _backend;

  /// Ouvre le panneau d'égaliseur du constructeur pour la session du lecteur.
  ///
  /// À n'appeler que si [backend] rend [EqualizerSystem] — ailleurs c'est un
  /// geste sans effet. Le réglage appartient alors au téléphone : le plugin ne
  /// peut ni le lire, ni le mémoriser.
  Future<void> openSystemPanel() =>
      RadioServicePlatform.instance.openSystemEqualizer();

  /// Dément la détection et bascule sur l'égaliseur du plugin, définitivement
  /// pour cette session. [backend] rendra ensuite [EqualizerPlugin].
  ///
  /// À offrir dans l'interface quand [backend] est [EqualizerSystem] : aucune
  /// API Android ne dit si le panneau du constructeur FAIT réellement quelque
  /// chose. Certaines images système en exposent un qui s'ouvre et se referme
  /// sans rien régler. Sans cette porte de sortie, la personne se retrouve avec
  /// un bouton inopérant et aucun curseur pour le remplacer.
  Future<void> useBuiltIn() async {
    await RadioServicePlatform.instance.useBuiltInEqualizer();
    _backend = null;   // la prochaine lecture de [backend] redemandera au natif
  }

  /// Applique la configuration — les changements sont immédiats.
  /// Sans effet quand [backend] est [EqualizerSystem].
  Future<void> apply(EqualizerConfig config) =>
      RadioServicePlatform.instance.setEqualizer(config);

  /// Remet l'égaliseur à plat (aucun effet)
  Future<void> reset() =>
      RadioServicePlatform.instance.setEqualizer(
        const EqualizerConfig.flat(),
      );
}