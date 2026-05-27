// Configuration de l'égaliseur audio — 5 bandes standard.
//
// Fréquences centrales Android standard :
//   sub    →   60 Hz  — sous-basses (profondeur, grondement)
//   bass   →  230 Hz  — basses (corps, chaleur)
//   mid    →  910 Hz  — médiums (voix, instruments)
//   high   → 3600 Hz  — hauts médiums (présence, clarté)
//   treble → 14000 Hz — aigus (brillance, air)
//
// Chaque bande est en décibels (dB) dans la plage [-15.0, +15.0].
// La plage réelle du matériel est [-1500, +1500] milliBels = ±15 dB.
// La conversion dB → mB est faite côté Kotlin.
class EqualizerConfig {

  /// Sous-basses ~60 Hz — profondeur, grondement
  final double sub;

  /// Basses ~230 Hz — corps, chaleur
  final double bass;

  /// Médiums ~910 Hz — voix, instruments
  final double mid;

  /// Hauts médiums ~3600 Hz — présence, clarté
  final double high;

  /// Aigus ~14000 Hz — brillance, air
  final double treble;

  const EqualizerConfig({
    this.sub    = 0.0,
    this.bass   = 0.0,
    this.mid    = 0.0,
    this.high   = 0.0,
    this.treble = 0.0,
  });

  /// Plat — aucun effet (défaut)
  const EqualizerConfig.flat()
      : sub    = 0.0,
        bass   = 0.0,
        mid    = 0.0,
        high   = 0.0,
        treble = 0.0;

  /// Accentue les basses — casque, enceinte portable
  const EqualizerConfig.bassBoost()
      : sub    = 6.0,
        bass   = 5.0,
        mid    = 0.0,
        high   = -1.0,
        treble = -2.0;

  /// Optimisé pour la voix — radio parlée, podcast
  const EqualizerConfig.vocal()
      : sub    = -3.0,
        bass   = -1.0,
        mid    = 4.0,
        high   = 3.0,
        treble = 1.0;

  /// Optimisé pour les hauts-parleurs de téléphone
  const EqualizerConfig.phone()
      : sub    = 3.0,
        bass   = 4.0,
        mid    = 2.0,
        high   = 3.0,
        treble = 4.0;

  /// Accentue les aigus — musique classique, acoustique
  const EqualizerConfig.trebleBoost()
      : sub    = -2.0,
        bass   = 0.0,
        mid    = 1.0,
        high   = 4.0,
        treble = 6.0;

  /// Profil "V" — basses et aigus accentués, médiums en retrait
  const EqualizerConfig.vShape()
      : sub    = 5.0,
        bass   = 4.0,
        mid    = -2.0,
        high   = 3.0,
        treble = 5.0;

  // Sérialise pour l'envoi via MethodChannel.
  // Les valeurs sont en dB — la conversion mB est faite côté Kotlin.
  Map<String, dynamic> toMap() => {
    'sub':    sub.clamp(-15.0,   15.0),
    'bass':   bass.clamp(-15.0,  15.0),
    'mid':    mid.clamp(-15.0,   15.0),
    'high':   high.clamp(-15.0,  15.0),
    'treble': treble.clamp(-15.0, 15.0),
  };
}