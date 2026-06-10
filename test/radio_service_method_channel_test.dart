// /// Tests unitaires — MethodChannelRadioService.
// ///
// /// Vérifie que chaque commande Dart invoque le bon nom de méthode
// /// sur le MethodChannel natif avec les bons arguments.
// library;
//
// import 'package:flutter/services.dart';
// import 'package:flutter_test/flutter_test.dart';
// import 'package:radio_service/radio_service_method_channel.dart';
// import 'package:radio_service/src/equalizer/equalizer_config.dart';
//
// void main() {
//   TestWidgetsFlutterBinding.ensureInitialized();
//
//   late MethodChannelRadioService platform;
//   const channel = MethodChannel('radio_service');
//
//   // Journal des appels reçus côté "natif"
//   final callLog = <MethodCall>[];
//
//   setUp(() {
//     callLog.clear();
//     platform = MethodChannelRadioService();
//     TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
//         .setMockMethodCallHandler(channel, (call) async {
//       callLog.add(call);
//       return null;
//     });
//   });
//
//   tearDown(() {
//     TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
//         .setMockMethodCallHandler(channel, null);
//   });
//
//   // ── setUrl ──────────────────────────────────────────────────────────────
//
//   group('setUrl', () {
//     test('invoque setUrl avec l\'URL proxy locale', () async {
//       await platform.setUrl('http://127.0.0.1:8888/stream');
//       expect(callLog, hasLength(1));
//       expect(callLog.first.method, equals('setUrl'));
//       expect(callLog.first.arguments['url'],
//           equals('http://127.0.0.1:8888/stream'));
//     });
//
//     test('l\'URL transmise est exactement celle reçue — pas de modification',
//         () async {
//       const proxyUrl = 'http://127.0.0.1:12345/stream';
//       await platform.setUrl(proxyUrl);
//       expect(callLog.first.arguments['url'], equals(proxyUrl));
//     });
//   });
//
//   // ── Commandes de lecture ─────────────────────────────────────────────────
//
//   group('commandes de lecture', () {
//     test('play invoque play', () async {
//       await platform.play();
//       expect(callLog.single.method, equals('play'));
//     });
//
//     test('pause invoque pause', () async {
//       await platform.pause();
//       expect(callLog.single.method, equals('pause'));
//     });
//
//     test('stop invoque stop', () async {
//       await platform.stop();
//       expect(callLog.single.method, equals('stop'));
//     });
//
//     test('setVolume envoie le bon volume', () async {
//       await platform.setVolume(0.75);
//       expect(callLog.single.method, equals('setVolume'));
//       expect(callLog.single.arguments['volume'], equals(0.75));
//     });
//   });
//
//   // ── Time-shift ───────────────────────────────────────────────────────────
//
//   group('time-shift', () {
//     test('seek envoie positionMs en millisecondes', () async {
//       await platform.seek(const Duration(seconds: 30));
//       expect(callLog.single.method, equals('seek'));
//       expect(callLog.single.arguments['positionMs'], equals(30000));
//     });
//
//     test('seekToLive invoque seekToLive', () async {
//       await platform.seekToLive();
//       expect(callLog.single.method, equals('seekToLive'));
//     });
//   });
//
//   // ── Notification ─────────────────────────────────────────────────────────
//
//   group('updateNativeMetadata', () {
//     test('envoie titre, artiste et artworkUrl', () async {
//       await platform.updateNativeMetadata(
//         title:      'Bohemian Rhapsody',
//         artist:     'Queen',
//         artworkUrl: 'https://example.com/cover.jpg',
//       );
//       expect(callLog.single.method, equals('updateMetadata'));
//       final args = callLog.single.arguments as Map;
//       expect(args['title'],      equals('Bohemian Rhapsody'));
//       expect(args['artist'],     equals('Queen'));
//       expect(args['artworkUrl'], equals('https://example.com/cover.jpg'));
//     });
//
//     test('n\'envoie que les champs non-null', () async {
//       await platform.updateNativeMetadata(title: 'Only Title');
//       final args = callLog.single.arguments as Map;
//       expect(args.containsKey('title'),      isTrue);
//       expect(args.containsKey('artist'),     isFalse);
//       expect(args.containsKey('artworkUrl'), isFalse);
//     });
//   });
//
//   // ── Égaliseur ────────────────────────────────────────────────────────────
//
//   group('setEqualizer', () {
//     test('envoie les 5 bandes correctement', () async {
//       await platform.setEqualizer(const EqualizerConfig(
//         sub: 3, bass: 6, mid: 0, high: -3, treble: -6,
//       ));
//       expect(callLog.single.method, equals('setEqualizer'));
//       final args = callLog.single.arguments as Map;
//       expect(args['sub'],    equals(3.0));
//       expect(args['bass'],   equals(6.0));
//       expect(args['mid'],    equals(0.0));
//       expect(args['high'],   equals(-3.0));
//       expect(args['treble'], equals(-6.0));
//     });
//   });
// }
