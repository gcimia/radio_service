import 'dart:typed_data';

// Toutes les métadonnées disponibles pour le morceau en cours.
// Construite progressivement par MetadataParser — les champs
// sont null tant qu'ils n'ont pas été reçus.
class PlayerMetadata {
  /// Titre du morceau
  final String? title;

  /// Artiste
  final String? artist;

  /// Album
  final String? album;

  /// Artwork embarqué dans les tags ID3 (APIC) — afficher avec Image.memory()
  final Uint8List? artworkData;

  /// URL d'artwork distante — afficher avec Image.network()
  final String? artworkUrl;

  /// Nom de la station radio (en-tête ICY icy-name)
  final String? stationName;

  /// Genre de la station (en-tête ICY icy-genre)
  final String? stationGenre;

  /// Heure de début de diffusion côté radio (fournie par le REST)
  final DateTime? broadcastTime;

  /// Indique si ces métadonnées viennent du polling REST.
  /// Utilisé par RadioService pour n'alimenter l'historique
  /// que depuis une seule source quand REST et ICY sont actifs.
  final bool fromRest;

  /// Vrai si le flux est connecté mais la radio ne diffuse rien.
  /// Déclenché après [_silenceTimeout] secondes sans StreamTitle ICY
  /// alors que le proxy reçoit bien des bytes (≠ coupure réseau).
  /// Permet d'informer l'utilisateur que la radio est inactive.
  final bool isSilent;

  const PlayerMetadata({
    this.title,
    this.artist,
    this.album,
    this.artworkData,
    this.artworkUrl,
    this.stationName,
    this.stationGenre,
    this.broadcastTime,
    this.fromRest  = false,
    this.isSilent  = false,
  });

  // Crée une copie en remplaçant uniquement les champs fournis.
  // Les champs null conservent leur valeur précédente.
  PlayerMetadata copyWith({
    String?    title,
    String?    artist,
    String?    album,
    Uint8List? artworkData,
    String?    artworkUrl,
    String?    stationName,
    String?    stationGenre,
    DateTime?  broadcastTime,
    bool?      fromRest,
    bool?      isSilent,
  }) {
    return PlayerMetadata(
      title:         title         ?? this.title,
      artist:        artist        ?? this.artist,
      album:         album         ?? this.album,
      artworkData:   artworkData   ?? this.artworkData,
      artworkUrl:    artworkUrl    ?? this.artworkUrl,
      stationName:   stationName   ?? this.stationName,
      stationGenre:  stationGenre  ?? this.stationGenre,
      broadcastTime: broadcastTime ?? this.broadcastTime,
      fromRest:      fromRest      ?? this.fromRest,
      isSilent:      isSilent      ?? this.isSilent,
    );
  }
}