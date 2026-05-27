// Position du lecteur dans le buffer audio.
// Sealed class — deux cas exclusifs : live ou dans le buffer.
sealed class PlayerPosition {}

/// Le lecteur est au live — aucun retard
class LivePosition extends PlayerPosition {}

/// Le lecteur est dans le buffer — en retard sur le live
class BufferedPosition extends PlayerPosition {
  /// Position actuelle de lecture
  final Duration current;

  /// Début du buffer disponible
  final Duration bufferStart;

  /// Fin du buffer = position du live bufferisé
  final Duration bufferEnd;

  /// Retard par rapport au live
  Duration get delayFromLive => bufferEnd - current;

  /// Progression de 0.0 à 1.0 — utilisée par le Slider Flutter
  double get progress {
    final total = (bufferEnd - bufferStart).inMilliseconds;
    if (total <= 0) return 1.0;
    return ((current - bufferStart).inMilliseconds / total)
        .clamp(0.0, 1.0);
  }

  BufferedPosition({
    required this.current,
    required this.bufferStart,
    required this.bufferEnd,
  });
}