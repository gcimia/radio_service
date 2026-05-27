// Configuration du comportement audio du lecteur.
// Toutes les valeurs ont des défauts raisonnables —
// ne configure que ce dont tu as besoin.
class BufferConfig {

  /// Durée minimale à mettre en buffer avant de commencer la lecture.
  /// Petit = latence réduite / Grand = plus stable sur réseau instable.
  final Duration minBufferDuration;

  /// Durée maximale conservée — définit jusqu'où on peut reculer (time-shift).
  final Duration maxBufferDuration;

  /// Latence cible par rapport au live.
  /// ExoPlayer ajuste automatiquement la vitesse pour maintenir ce délai.
  final Duration targetLiveLatency;

  /// Latence maximale tolérée avant qu'ExoPlayer accélère pour rattraper.
  /// Doit être supérieure à [targetLiveLatency].
  final Duration maxLiveLatency;

  /// Vitesse de rattrapage quand la latence dépasse [maxLiveLatency].
  /// 1.05 = accélère de 5% — imperceptible à l'oreille.
  final double catchUpSpeed;

  const BufferConfig({
    this.minBufferDuration = const Duration(seconds: 5),
    this.maxBufferDuration = const Duration(minutes: 30),
    this.targetLiveLatency = const Duration(seconds: 5),
    this.maxLiveLatency    = const Duration(seconds: 10),
    this.catchUpSpeed      = 1.05,
  });

  /// Profil latence minimale — radios d'actualité, sport en direct
  const BufferConfig.lowLatency()
      : minBufferDuration = const Duration(seconds: 2),
        maxBufferDuration = const Duration(minutes: 30),
        targetLiveLatency = const Duration(seconds: 3),
        maxLiveLatency    = const Duration(seconds: 6),
        catchUpSpeed      = 1.05;

  /// Profil stabilité maximale — connexions instables (3G, WiFi faible)
  const BufferConfig.stable()
      : minBufferDuration = const Duration(seconds: 15),
        maxBufferDuration = const Duration(minutes: 30),
        targetLiveLatency = const Duration(seconds: 15),
        maxLiveLatency    = const Duration(seconds: 30),
        catchUpSpeed      = 1.02;

  Map<String, dynamic> toMap() => {
    'minBufferMs':     minBufferDuration.inMilliseconds,
    'maxBufferMs':     maxBufferDuration.inMilliseconds,
    'targetLatencyMs': targetLiveLatency.inMilliseconds,
    'maxLatencyMs':    maxLiveLatency.inMilliseconds,
    'catchUpSpeed':    catchUpSpeed,
  };
}