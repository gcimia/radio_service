/// Bancs de la couche flux — politique de reconnexion et jeton de génération.
///
/// Ces tests tournent sur la VM Dart (dart:io disponible) et n'utilisent
/// aucun réseau externe : un petit serveur ICY local joue le rôle de la radio.
/// Ils couvrent le lot « verrou source error » :
///
///   1. le lecteur se reconnecte tout seul quand le flux se coupe ;
///   2. il ne s'arrête JAMAIS de lui-même — pas de plafond de tentatives ;
///   3. stop() l'arrête vraiment, et définitivement ;
///   4. changer de station pendant un incident ne laisse pas l'ancien flux
///      pousser ses octets dans le nouveau (le défaut d'origine) ;
///   5. le proxy audio sert bien ce qu'on lui pousse, et s'arrête proprement.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:radio_service/src/player/player_state.dart';
import 'package:radio_service/src/stream/audio_proxy_server.dart';
import 'package:radio_service/src/stream/icy_stream_reader.dart';

// ---------------------------------------------------------------------------
// Serveur ICY local — émet en boucle un octet identifiant la « station ».
// ---------------------------------------------------------------------------

class _FakeIcyServer {
  _FakeIcyServer(this.marker);

  /// Octet émis en boucle — permet de savoir DE QUELLE station vient un chunk.
  final int marker;

  HttpServer?         _server;
  final _responses    = <HttpResponse>[];
  Timer?              _ticker;

  /// Nombre de connexions acceptées — mesure les tentatives du lecteur.
  int connections = 0;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;

    server.listen((request) async {
      connections++;
      final response = request.response;
      response.statusCode = 200;
      response.headers
        ..set('content-type', 'audio/mpeg')
        ..set('icy-name', 'Station ${String.fromCharCode(marker)}');
      // Pas d'icy-metaint : tout le corps est de l'audio.
      _responses.add(response);
      _push(response);
    });

    _ticker ??= Timer.periodic(const Duration(milliseconds: 20), (_) {
      for (final r in List<HttpResponse>.from(_responses)) {
        _push(r);
      }
    });

    return 'http://127.0.0.1:${server.port}/stream';
  }

  void _push(HttpResponse response) {
    try {
      response.add(Uint8List.fromList(List<int>.filled(16, marker)));
    } catch (_) {
      _responses.remove(response);
    }
  }

  /// Coupe les flux en cours sans fermer le serveur — simule une rupture
  /// réseau : le lecteur doit se reconnecter sur le même port.
  Future<void> dropStreams() async {
    final open = List<HttpResponse>.from(_responses);
    _responses.clear();
    for (final r in open) {
      try {
        await r.close();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    _ticker?.cancel();
    _ticker = null;
    await dropStreams();
    await _server?.close(force: true);
    _server = null;
  }
}

/// Réserve un port puis le libère — donne une URL garantie injoignable.
Future<String> _unreachableUrl() async {
  final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port  = probe.port;
  await probe.close(force: true);
  return 'http://127.0.0.1:$port/stream';
}

void main() {
  // ── Nouvel état ───────────────────────────────────────────────────────────

  group('PlayerInterrupted', () {
    test('est un PlayerState distinct de Stopped et de Error', () {
      final state = PlayerInterrupted();
      expect(state, isA<PlayerState>());
      expect(state, isNot(isA<PlayerStopped>()));
      expect(state, isNot(isA<PlayerError>()));
    });
  });

  // ── Politique de recul ────────────────────────────────────────────────────

  group('Recul de reconnexion', () {
    test('table par défaut : 1, 2, 4, 8, 15 s', () {
      expect(
        IcyStreamReader.defaultBackoffDelays.map((d) => d.inSeconds).toList(),
        equals(<int>[1, 2, 4, 8, 15]),
      );
    });

    test('la dernière valeur est bornée, pas dépassée', () {
      final delays = IcyStreamReader.defaultBackoffDelays;
      expect(delays.last, equals(const Duration(seconds: 15)));
    });
  });

  // ── Reconnexion automatique ───────────────────────────────────────────────

  group('IcyStreamReader — reconnexion', () {
    test('se reconnecte seul après une coupure du flux', () async {
      final server = _FakeIcyServer(0x41); // 'A'
      final url    = await server.start();

      final reader = IcyStreamReader(
        backoffDelays: const [Duration(milliseconds: 50)],
      );

      var received = 0;
      reader.onAudioBytes = (bytes) { received += bytes.length; };

      await reader.start(url);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(received, greaterThan(0), reason: 'le flux initial doit couler');
      expect(server.connections, equals(1));

      // Rupture en cours de flux.
      await server.dropStreams();
      final beforeRecovery = received;

      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(server.connections, greaterThan(1),
          reason: 'le lecteur doit avoir retenté');
      expect(received, greaterThan(beforeRecovery),
          reason: 'l\'audio doit avoir repris');

      await reader.stop();
      await server.dispose();
    });

    test('ne renonce jamais : bien au-delà des 5 tentatives d\'avant',
        () async {
      final url = await _unreachableUrl();

      var unavailable = 0;
      var errors      = 0;

      final reader = IcyStreamReader(
        connectTimeout:   const Duration(milliseconds: 100),
        backoffDelays:    const [Duration(milliseconds: 20)],
        interruptedAfter: const Duration(milliseconds: 50),
      )
        // Corps en bloc et non `=>` : un corps fléché s'étend le plus loin
        // possible et avalait la cascade suivante — `unavailable++ ..onError`,
        // d'où « The setter 'onError' isn't defined for the type 'int' ».
        ..onUnavailable = () { unavailable++; }
        ..onError       = (_) { errors++; };

      await reader.start(url);
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(errors, greaterThan(5),
          reason: 'l\'ancien plafond de 5 tentatives ne doit plus exister');
      expect(unavailable, equals(1),
          reason: 'l\'avis d\'interruption n\'est émis qu\'une fois par épisode');

      await reader.stop();
    });

    test('stop() arrête vraiment la boucle', () async {
      final url = await _unreachableUrl();

      var errors = 0;
      final reader = IcyStreamReader(
        connectTimeout: const Duration(milliseconds: 100),
        backoffDelays:  const [Duration(milliseconds: 20)],
      )..onError = (_) { errors++; };

      await reader.start(url);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await reader.stop();

      final frozen = errors;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(errors, equals(frozen),
          reason: 'plus aucune tentative après stop()');
      expect(reader.isRunning, isFalse);
    });

    test('changer de station ne laisse pas l\'ancien flux pousser ses octets',
        () async {
      final serverA = _FakeIcyServer(0x41); // 'A'
      final serverB = _FakeIcyServer(0x42); // 'B'
      final urlA = await serverA.start();
      final urlB = await serverB.start();

      final reader = IcyStreamReader(
        backoffDelays: const [Duration(milliseconds: 50)],
      );

      var seenA = 0;
      var seenB = 0;
      reader.onAudioBytes = (bytes) {
        for (final b in bytes) {
          if (b == 0x41) seenA++;
          if (b == 0x42) seenB++;
        }
      };

      await reader.start(urlA);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(seenA, greaterThan(0));

      // Changement de station — le serveur A continue d'émettre dans le vide.
      await reader.start(urlB);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final aAfterSwitch = seenA;
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(seenB, greaterThan(0), reason: 'la station B doit couler');
      expect(seenA, equals(aAfterSwitch),
          reason: 'plus un seul octet de la station A après le changement');

      await reader.stop();
      await serverA.dispose();
      await serverB.dispose();
    });

    test('retryNow() raccourcit le recul en cours', () async {
      final url = await _unreachableUrl();

      var errors = 0;
      final reader = IcyStreamReader(
        connectTimeout: const Duration(milliseconds: 100),
        // Recul volontairement très long : sans retryNow, une seule tentative.
        backoffDelays:  const [Duration(seconds: 30)],
      )..onError = (_) { errors++; };

      await reader.start(url);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final beforeRetry = errors;

      reader.retryNow();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(errors, greaterThan(beforeRetry),
          reason: 'retryNow doit relancer sans attendre les 30 s');

      await reader.stop();
    });
  });

  // ── Proxy audio ───────────────────────────────────────────────────────────

  group('AudioProxyServer', () {
    test('sert les octets poussés puis s\'arrête proprement', () async {
      final proxy = AudioProxyServer();
      await proxy.start();

      final client  = HttpClient();
      final request = await client.getUrl(Uri.parse(proxy.streamUrl));

      // Le proxy n'envoie ses en-têtes qu'au premier octet écrit : on pousse
      // en continu, comme le ferait IcyStreamReader, sinon la réponse
      // n'arrive jamais côté client.
      final pusher = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => proxy.pushAudioBytes(Uint8List.fromList(<int>[1, 2, 3, 4])),
      );

      final response = await request.close();
      final received = <int>[];
      final sub      = response.listen(received.addAll);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      pusher.cancel();

      expect(received.length, greaterThanOrEqualTo(4));
      expect(received.take(4).toList(), equals(<int>[1, 2, 3, 4]));

      await proxy.stop();

      // Après stop : la file est fermée, pousser ne doit plus rien lever.
      expect(() => proxy.pushAudioBytes(Uint8List.fromList(<int>[9])),
          returnsNormally);

      await sub.cancel();
      client.close(force: true);
    });
  });
}
