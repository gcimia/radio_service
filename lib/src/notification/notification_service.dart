import 'dart:typed_data';

import '../../radio_service_platform_interface.dart';

// Met à jour le contenu de la notification de lecture
// et de l'écran de verrouillage.
// Appelé automatiquement par RadioService à chaque changement de titre —
// l'utilisateur du plugin n'a pas besoin d'appeler ces méthodes directement.
class NotificationService {

  /// Met à jour le titre, l'artiste et la pochette
  /// dans la notification et sur l'écran de verrouillage.
  ///
  /// [artworkBytes] : bytes de l'image déjà téléchargée côté Dart.
  /// Kotlin reçoit les bytes directement sans refaire d'appel réseau.
  Future<void> update({
    String?    title,
    String?    artist,
    Uint8List? artworkBytes,
  }) =>
      RadioServicePlatform.instance.updateNativeMetadata(
        title:        title,
        artist:       artist,
        artworkBytes: artworkBytes,
      );
}
