/// Configuration du résolveur d'artwork externe.
library;

// ---------------------------------------------------------------------------
// Sources d'artwork — sealed class
// ---------------------------------------------------------------------------

/// Représente une source d'artwork externe.
/// Sealed = exhaustive dans les switch, pas de cas non gérés possibles.
sealed class ArtworkSource {
  const ArtworkSource();
}

/// Source iTunes Search API (gratuite, sans clé).
/// Priorité par défaut — meilleure base de données internationale,
/// retourne `collectionType` pour distinguer album studio/compilation.
final class ArtworkSourceItunes extends ArtworkSource {
  const ArtworkSourceItunes();
}

/// Source Deezer API (gratuite, sans clé).
/// Fallback — couvre les artistes absents d'iTunes (musique régionale…),
/// retourne `record_type` pour la priorité album studio.
final class ArtworkSourceDeezer extends ArtworkSource {
  const ArtworkSourceDeezer();
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Configuration injectée dans [ArtworkResolver].
///
/// ```dart
/// // Configuration par défaut (iTunes → Deezer)
/// const config = ArtworkResolverConfig();
///
/// // Deezer en priorité
/// final config = ArtworkResolverConfig(
///   priority: [ArtworkSourceDeezer(), ArtworkSourceItunes()],
/// );
///
/// // Désactivé
/// const config = ArtworkResolverConfig.disabled;
/// ```
class ArtworkResolverConfig {
  const ArtworkResolverConfig({
    this.enabled = true,
    this.priority = const [ArtworkSourceItunes(), ArtworkSourceDeezer()],
    this.memoryCacheSize = 200,
    this.diskCacheDuration = const Duration(days: 7),
    this.requestTimeout = const Duration(seconds: 6),
    this.diskCacheDir,
  });

  /// Active ou désactive la résolution automatique.
  final bool enabled;

  /// Ordre de priorité des sources. La première source valide est utilisée.
  final List<ArtworkSource> priority;

  /// Nombre maximum d'entrées dans le cache mémoire (LRU).
  final int memoryCacheSize;

  /// Durée de validité des entrées sur disque.
  final Duration diskCacheDuration;

  /// Timeout par requête HTTP.
  final Duration requestTimeout;

  /// Répertoire de cache disque. Si null, utilise le cache de l'application.
  final String? diskCacheDir;

  /// Config désactivée — utile pour les tests ou le mode hors-ligne.
  static const disabled = ArtworkResolverConfig(enabled: false);

  ArtworkResolverConfig copyWith({
    bool? enabled,
    List<ArtworkSource>? priority,
    int? memoryCacheSize,
    Duration? diskCacheDuration,
    Duration? requestTimeout,
    String? diskCacheDir,
  }) {
    return ArtworkResolverConfig(
      enabled:           enabled           ?? this.enabled,
      priority:          priority          ?? this.priority,
      memoryCacheSize:   memoryCacheSize   ?? this.memoryCacheSize,
      diskCacheDuration: diskCacheDuration ?? this.diskCacheDuration,
      requestTimeout:    requestTimeout    ?? this.requestTimeout,
      diskCacheDir:      diskCacheDir      ?? this.diskCacheDir,
    );
  }
}
