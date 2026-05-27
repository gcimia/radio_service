// Décrit comment lire les champs titre, artiste, artwork et heure de début
// dans la réponse JSON d'un endpoint REST propriétaire.
//
// Chaque champ accepte un "chemin pointé" pour les JSON imbriqués :
//   'title'           → json['title']
//   'data.song'       → json['data']['song']
//   'result.track.name' → json['result']['track']['name']
class MetadataMapping {
  /// Chemin vers le titre du morceau
  final String? title;

  /// Chemin vers le nom de l'artiste
  final String? artist;

  /// Chemin vers l'URL de la pochette
  final String? artworkUrl;

  /// Chemin vers l'heure de début de diffusion.
  /// Formats acceptés : timestamp Unix (int), ISO 8601, HH:mm ou HH:mm:ss
  final String? startTime;

  const MetadataMapping({
    this.title,
    this.artist,
    this.artworkUrl,
    this.startTime,
  });

  /// Résout un chemin pointé dans un JSON décodé.
  /// Retourne null si le chemin n'existe pas ou si la valeur n'est pas une String.
  String? resolve(Map<String, dynamic> json, String? path) {
    if (path == null) return null;
    final keys = path.split('.');
    dynamic current = json;
    for (final key in keys) {
      if (current is! Map<String, dynamic>) return null;
      current = current[key];
    }
    return current?.toString();
  }
}