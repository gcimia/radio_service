/// AudioProxyServer — serveur HTTP local 127.0.0.1:PORT.
///
/// Reçoit les bytes audio purs de [IcyStreamReader] et les sert
/// à ExoPlayer via une URL locale http://127.0.0.1:PORT/stream.
///
/// ExoPlayer reçoit une URL HTTP classique — il ne sait pas que
/// c'est un proxy. Il gère le buffering et le décodage audio
/// exactement comme d'habitude.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

class AudioProxyServer {
  AudioProxyServer({this.port = 0}); // 0 = port libre choisi par l'OS

  final int port;

  HttpServer? _server;
  HttpRequest? _currentRequest;

  // File d'attente des chunks audio à servir
  final _queue          = StreamController<Uint8List>.broadcast();
  String? _contentType;

  // ── API publique ────────────────────────────────────────────────────────

  /// Port effectivement utilisé (disponible après [start])
  int get effectivePort => _server?.port ?? 0;

  /// URL locale à donner à ExoPlayer
  String get streamUrl => 'http://127.0.0.1:$effectivePort/stream';

  /// Démarre le serveur proxy.
  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);

    // ── DEBUG ──────────────────────────────────────────────────────────────
    debugPrint('[AudioProxyServer] démarré sur $streamUrl');
    // ── FIN DEBUG ──────────────────────────────────────────────────────────

    _server!.listen(_handleRequest);
  }

  /// Arrête le serveur et ferme toutes les connexions.
  Future<void> stop() async {
    await _currentRequest?.response.close().catchError((_) {});
    _currentRequest = null;
    await _server?.close(force: true);
    _server = null;

    // ── DEBUG ──────────────────────────────────────────────────────────────
    debugPrint('[AudioProxyServer] arrêté');
    // ── FIN DEBUG ──────────────────────────────────────────────────────────
  }

  /// Définit le Content-Type du flux (audio/mpeg, audio/aac…)
  /// à transmettre dans les headers HTTP à ExoPlayer.
  void setContentType(String contentType) {
    _contentType = contentType;
  }

  /// Transmet un chunk de bytes audio au client (ExoPlayer).
  void pushAudioBytes(Uint8List bytes) {
    if (!_queue.isClosed) _queue.add(bytes);
  }

  /// Réinitialise le proxy pour un nouveau flux.
  void reset() {
    // Ferme la connexion en cours — ExoPlayer se reconnectera
    _currentRequest?.response.close().catchError((_) {});
    _currentRequest = null;
    _contentType    = null;
  }

  // ── Gestion des requêtes HTTP ───────────────────────────────────────────

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != '/stream') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    // ── DEBUG ──────────────────────────────────────────────────────────────
    debugPrint('[AudioProxyServer] ExoPlayer connecté');
    // ── FIN DEBUG ──────────────────────────────────────────────────────────

    _currentRequest = request;

    // Headers de réponse — simule un flux ICY/HTTP standard
    request.response.statusCode = HttpStatus.ok;
    request.response.headers
      ..set(HttpHeaders.contentTypeHeader,
            _contentType ?? 'audio/mpeg')
      ..set(HttpHeaders.transferEncodingHeader, 'chunked')
      ..set('Cache-Control', 'no-cache, no-store')
      ..set('Connection',    'keep-alive')
      ..set('X-Proxy',       'radio_service');

    // Streaming des bytes vers ExoPlayer
    final sub = _queue.stream.listen(
      (bytes) {
        try {
          request.response.add(bytes);
        } catch (_) {
          // ExoPlayer a fermé la connexion
        }
      },
      onDone: () => request.response.close().catchError((_) {}),
    );

    // Attend que la connexion se ferme
    await request.response.done.catchError((_) {});
    await sub.cancel();

    // ── DEBUG ──────────────────────────────────────────────────────────────
    debugPrint('[AudioProxyServer] ExoPlayer déconnecté');
    // ── FIN DEBUG ──────────────────────────────────────────────────────────

    _currentRequest = null;
  }
}
