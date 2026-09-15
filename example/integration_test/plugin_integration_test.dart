// Test d'intégration — tourne dans une vraie application Flutter, donc face
// à l'implémentation native du plugin (contrairement aux tests unitaires Dart).
//
// https://flutter.dev/to/integration-testing

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:radio_service/radio_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Fumigène : la construction envoie configure() au natif et dispose()
  // déclenche release(). Si le canal ou l'enregistrement du plugin sont
  // cassés, ce test échoue avant tout le reste.
  testWidgets('construction et libération sans erreur native',
      (WidgetTester tester) async {
    final service = RadioService(
      equalizerEnabled:  false,
      backgroundEnabled: false,
    );
    await service.dispose();
  });
}
