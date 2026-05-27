import '../../radio_service_platform_interface.dart';

// Applique une configuration d'égaliseur au lecteur audio.
// Peut être appelé à tout moment, même pendant la lecture.
class EqualizerService {

  /// Applique la configuration — les changements sont immédiats
  Future<void> apply(EqualizerConfig config) =>
      RadioServicePlatform.instance.setEqualizer(config);

  /// Remet l'égaliseur à plat (aucun effet)
  Future<void> reset() =>
      RadioServicePlatform.instance.setEqualizer(
        const EqualizerConfig.flat(),
      );
}