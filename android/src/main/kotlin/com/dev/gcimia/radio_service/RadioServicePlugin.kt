package com.dev.gcimia.radio_service

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.media3.common.util.UnstableApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Point d'entrée du plugin Flutter.
// Crée le player, démarre le MediaSessionService si demandé,
// et met en place les canaux de communication avec Dart.
//
// Implémente ActivityAware pour accéder à l'Activity — requis pour demander
// la permission POST_NOTIFICATIONS sur Android 13+ (API 33+).
// Sans cette permission, la notification media n'apparaît pas et l'écran
// de verrouillage ne montre pas les contrôles de lecture.
@UnstableApi
class RadioServicePlugin : FlutterPlugin, ActivityAware {

    private lateinit var methodChannel:     MethodChannel
    private lateinit var eventChannel:      EventChannel
    private lateinit var permissionChannel: MethodChannel
    private lateinit var handler:           RadioPlayerHandler
    private lateinit var appContext:        Context
    private var activity: Activity? = null

    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1001
    }

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

        // Canal pour la demande de permission notification (Android 13+)
        permissionChannel = MethodChannel(
            binding.binaryMessenger,
            "radio_service/permissions",
        )
        permissionChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> {
                    requestNotificationPermission()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        permissionChannel.setMethodCallHandler(null)
        handler.dispose()
    }

    // ── ActivityAware ─────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    // ── Permission POST_NOTIFICATIONS (Android 13+) ────────────────────────────

    /// Demande la permission d'afficher des notifications sur Android 13+.
    /// Sur Android < 13, les notifications sont autorisées sans permission explicite.
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return  // < Android 13

        val act = activity ?: return  // pas d'activity disponible

        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (ContextCompat.checkSelfPermission(act, permission)
            == PackageManager.PERMISSION_GRANTED) return  // déjà accordée

        // Demande la permission — la boîte de dialogue système s'affiche
        ActivityCompat.requestPermissions(
            act,
            arrayOf(permission),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
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