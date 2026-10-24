package com.dev.gcimia.radio_service

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Point d'entrée du plugin Flutter.
// Crée le player, démarre le MediaSessionService si demandé,
// et met en place les canaux de communication avec Dart.
//
// Le plugin ne demande AUCUNE permission d'exécution. La notification du
// lecteur passe par une MediaSession, et Android exempte explicitement ces
// notifications de POST_NOTIFICATIONS :
//   « Notifications related to media sessions are exempt from this behavior
//     change. »
// C'est pourquoi elle s'affiche alors que rien n'a jamais été accordé.
// Une application hôte qui veut poster SES propres notifications demande la
// permission elle-même — c'est son rôle, pas celui du plugin.
@UnstableApi
class RadioServicePlugin : FlutterPlugin {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel:  EventChannel
    private lateinit var handler:       RadioPlayerHandler
    private lateinit var appContext:    Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext

        // Crée le canal de notification dès l'initialisation du plugin.
        // Media3 l'utilisera automatiquement via DefaultMediaNotificationProvider.
        RadioNotificationManager(appContext)

        val eventStream = PlayerEventStream()
        handler = RadioPlayerHandler(appContext, eventStream, ::onConfigure, ::stopRadioService)

        methodChannel = MethodChannel(binding.binaryMessenger, "radio_service")
        methodChannel.setMethodCallHandler(handler)

        eventChannel = EventChannel(binding.binaryMessenger, "radio_service/events")
        eventChannel.setStreamHandler(eventStream)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        handler.dispose()
    }

    // ── ForegroundService ─────────────────────────────────────────────────────

    /// Callback appelé par RadioPlayerHandler quand "configure" est reçu.
    /// C'est ici qu'on décide de démarrer ou non le ForegroundService.
    private fun onConfigure(backgroundEnabled: Boolean) {
        if (backgroundEnabled) {
            // Partage le player AVANT de démarrer le service
            RadioMediaService.sharedPlayer = handler.getPlayer()
            val intent = Intent(appContext, RadioMediaService::class.java)
            // ContextCompat.startForegroundService() est compatible avec toutes les API :
            //   API 26+ → startForegroundService() (requis pour les foreground services)
            //   API 21-25 → startService() (startForegroundService n'existe pas encore)
            // Évite le crash NoSuchMethodError sur Android 7.0 (API 24-25)
            ContextCompat.startForegroundService(appContext, intent)
        } else {
            // Fonctionnalité désactivée → on libère la ressource associée.
            stopRadioService()
        }
    }

    /// Arrête le foreground service (et donc libère player + MediaSession +
    /// notification via RadioMediaService.onDestroy). Idempotent : sans effet
    /// si le service n'est pas démarré.
    private fun stopRadioService() {
        appContext.stopService(Intent(appContext, RadioMediaService::class.java))
    }
}