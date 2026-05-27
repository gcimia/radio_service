import 'player_metadata.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

// Parse les événements bruts reçus du canal natif et maintient
// un état cohérent de PlayerMetadata.
//
// Principe fondamental : chaque source est stockée séparément.
// La fusion applique des règles de priorité explicites.
//
// Règles de priorité titre/artiste :
//   REST > ICY > ID3 inline > Vorbis > Media*
//   (* Media = tags ID3 du fichier original lu par ExoPlayer.
//      Ignorés dès qu'une ICY est reçue car ils correspondent
//      au morceau original encodé, pas à ce qui passe à la radio.)
//
// Règles artwork :
//   ID3 APIC inline > URL REST
//   (Media artwork ignoré si ICY présente)
class MetadataParser {

  // ── États séparés par source ───────────────────────────────────────────────

  // Infos station — stables pour toute la durée de la connexion
  String? _stationName;
  String? _stationGenre;

  // Source ICY inline (StreamTitle dans le flux)
  // Pour les radios live, c'est la source la plus fiable — elle reflète
  // ce qui est diffusé, pas les tags ID3 du fichier encodé.
  String? _icyTitle;
  String? _icyArtist;
  String? _lastIcyRaw;

  // Indique qu'au moins une ICY a été reçue sur ce flux.
  // Quand true, les données 'media' (tags ID3 du fichier) sont ignorées
  // car elles correspondent au morceau original et non à la diffusion.
  bool _hasIcy = false;

  // Source ID3 texte inline (TIT2/TPE1/TALB embarqués dans le flux)
  String? _id3Title;
  String? _id3Artist;
  String? _id3Album;
  Uint8List? _id3ArtworkData;

  // Source Vorbis (OGG/Opus)
  String? _vorbisTitle;
  String? _vorbisArtist;
  String? _vorbisAlbum;

  // Source Media — tags ID3 du fichier MP3 lu par ExoPlayer.
  // Utilisés uniquement si aucune ICY n'a été reçue (podcasts, fichiers).
  String? _mediaTitle;
  String? _mediaArtist;
  Uint8List? _mediaArtworkData;

  // Source REST (polling externe)
  String?   _restTitle;
  String?   _restArtist;
  String?   _restAlbum;
  String?   _restArtworkUrl;
  DateTime? _restBroadcastTime;
  bool      _hasRest = false;

  // ── API publique ───────────────────────────────────────────────────────────

  /// Dernier état fusionné
  PlayerMetadata get current => _merge();

  /// Reçoit un événement brut du canal natif.
  /// Retourne le nouveau PlayerMetadata si l'événement est reconnu, null sinon.
  PlayerMetadata? parse(Map<String, dynamic> event) {
    if (event['type'] != 'metadata') return null;
    final source = event['source'] as String?;
    if (source == null) return null;

    // ── DEBUG ────────────────────────────────────────────────────────────────
    debugPrint('[MetadataParser] event reçu → source:"$source" data:$event');
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    final changed = switch (source) {
      'icy_info'    => _parseIcyInfo(event),
      'icy_header'  => _parseIcyHeader(event),
      'id3_text'    => _parseId3Text(event),
      'id3_artwork' => _parseId3Artwork(event),
      'vorbis'      => _parseVorbis(event),
      'media'       => _parseMedia(event),
      _             => false,
    };

    // ── DEBUG ────────────────────────────────────────────────────────────────
    if (changed) {
      final m = _merge();
      debugPrint('[MetadataParser] → émission → '
          'title:"${m.title}" artist:"${m.artist}"');
    }
    // ── FIN DEBUG ────────────────────────────────────────────────────────────

    return changed ? _merge() : null;
  }

  /// Fusionne des métadonnées REST avec l'état courant.
  /// Les champs null dans [incoming] n'écrasent pas les valeurs REST précédentes.
  PlayerMetadata mergeRestMetadata(PlayerMetadata incoming) {
    if (incoming.title         != null) _restTitle         = incoming.title;
    if (incoming.artist        != null) _restArtist        = incoming.artist;
    if (incoming.album         != null) _restAlbum         = incoming.album;
    if (incoming.artworkUrl    != null) _restArtworkUrl    = incoming.artworkUrl;
    if (incoming.broadcastTime != null) _restBroadcastTime = incoming.broadcastTime;
    _hasRest = true;
    return _merge(fromRest: true);
  }

  /// Réinitialise complètement l'état — à appeler à chaque changement de flux.
  void reset() {
    _stationName       = null;
    _stationGenre      = null;
    _lastIcyRaw        = null;
    _icyTitle          = null;
    _icyArtist         = null;
    _hasIcy            = false;
    _id3Title          = null;
    _id3Artist         = null;
    _id3Album          = null;
    _id3ArtworkData    = null;
    _vorbisTitle       = null;
    _vorbisArtist      = null;
    _vorbisAlbum       = null;
    _mediaTitle        = null;
    _mediaArtist       = null;
    _mediaArtworkData  = null;
    _restTitle         = null;
    _restArtist        = null;
    _restAlbum         = null;
    _restArtworkUrl    = null;
    _restBroadcastTime = null;
    _hasRest           = false;
  }

  // ── Fusion ────────────────────────────────────────────────────────────────

  PlayerMetadata _merge({bool fromRest = false}) {
    final useMedia = !_hasIcy;

    final title  = _restTitle  ?? _icyTitle
                ?? _id3Title   ?? _vorbisTitle
                ?? (useMedia ? _mediaTitle  : null);
    final artist = _restArtist ?? _icyArtist
                ?? _id3Artist  ?? _vorbisArtist
                ?? (useMedia ? _mediaArtist : null);
    final album  = _restAlbum  ?? _id3Album ?? _vorbisAlbum;

    final artworkData = _id3ArtworkData
                     ?? (useMedia ? _mediaArtworkData : null);

    return PlayerMetadata(
      title:         title,
      artist:        artist,
      album:         album,
      artworkData:   artworkData,
      artworkUrl:    _restArtworkUrl,
      stationName:   _stationName,
      stationGenre:  _stationGenre,
      broadcastTime: _restBroadcastTime,
      fromRest:      fromRest,
    );
  }

  // ── Parsers privés ────────────────────────────────────────────────────────

  // ICY inline — source principale pour les flux radio live.
  // Reçoit artist et title déjà parsés par IcyStreamReader/StreamTitleParser.
  // Dès la première ICY, les données 'media' sont désactivées.
  bool _parseIcyInfo(Map<String, dynamic> e) {
    final title  = e['title']  as String? ?? '';
    final artist = e['artist'] as String?;
    final raw    = '$artist|$title'; // clé de déduplication

    if (title.isEmpty) return false;
    if (raw == _lastIcyRaw) return false; // répétition serveur
    _lastIcyRaw = raw;
    _hasIcy     = true;

    _icyTitle  = title.isEmpty  ? null : title;
    _icyArtist = (artist?.isEmpty ?? true) ? null : artist;

    // Nouveau morceau → efface les données REST du morceau précédent
    if (_hasRest) {
      _restTitle         = null;
      _restArtist        = null;
      _restAlbum         = null;
      _restArtworkUrl    = null;
      _restBroadcastTime = null;
    }

    return true;
  }

  // En-têtes ICY reçus à la connexion (nom station, genre)
  bool _parseIcyHeader(Map<String, dynamic> e) {
    _stationName  = e['stationName']  as String? ?? _stationName;
    _stationGenre = e['stationGenre'] as String? ?? _stationGenre;
    return true;
  }

  // Tags ID3 texte inline (distincts des tags 'media' du fichier)
  bool _parseId3Text(Map<String, dynamic> e) {
    final frameId = e['frameId'] as String? ?? '';
    final value   = e['value']   as String? ?? '';
    switch (frameId) {
      case 'TIT2': _id3Title  = value;
      case 'TPE1': _id3Artist = value;
      case 'TALB': _id3Album  = value;
      default: return false;
    }
    return true;
  }

  // Artwork ID3 embarqué (APIC)
  bool _parseId3Artwork(Map<String, dynamic> e) {
    final list = e['data'] as List?;
    if (list == null) return false;
    _id3ArtworkData = Uint8List.fromList(list.cast<int>());
    return true;
  }

  // Vorbis comments (OGG/Opus)
  bool _parseVorbis(Map<String, dynamic> e) {
    final key   = e['key']   as String? ?? '';
    final value = e['value'] as String? ?? '';
    switch (key) {
      case 'TITLE':  _vorbisTitle  = value;
      case 'ARTIST': _vorbisArtist = value;
      case 'ALBUM':  _vorbisAlbum  = value;
      default: return false;
    }
    return true;
  }

  // Tags du fichier MP3 lus par ExoPlayer.
  // Ignorés silencieusement si le flux est ICY (radio live).
  bool _parseMedia(Map<String, dynamic> e) {
    if (_hasIcy) return false;

    final artworkList = e['data'] as List?;
    final title  = e['title']  as String?;
    final artist = e['artist'] as String?;
    if (title  != null) _mediaTitle  = title;
    if (artist != null) _mediaArtist = artist;
    if (artworkList != null) {
      _mediaArtworkData = Uint8List.fromList(artworkList.cast<int>());
    }
    return title != null || artist != null || artworkList != null;
  }
}
