import '../../radio_service_platform_interface.dart';

// Interface Dart pour le service de lecture en arrière-plan.
// La logique réelle est dans RadioMediaService.kt côté Android
// et son équivalent sur les autres plateformes.
// Ce fichier documente le contrat et sert de point d'entrée
// pour les éventuelles commandes spécifiques au background.
class BackgroundService {

  /// Vérifie si le service background est actif.
  /// Utile pour adapter l'UI (ex: afficher un indicateur de lecture en cours).
  Future<bool> isRunning() =>
      RadioServicePlatform.instance.isBackgroundServiceRunning();
}