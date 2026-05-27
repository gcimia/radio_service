package com.dev.gcimia.radio_service

import android.content.Context
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Reçoit les commandes Dart et les délègue à RadioExoPlayer.
@UnstableApi
class RadioPlayerHandler(                                            // ← OUVERTURE CLASSE
    context: Context,
    eventStream: PlayerEventStream,
    private val onConfigure: (backgroundEnabled: Boolean) -> Unit = {},
) : MethodChannel.MethodCallHandler {

    private val player = RadioExoPlayer(context, eventStream)

    // Expose le player pour le partage avec RadioMediaService
    fun getPlayer(): ExoPlayer = player.getExoPlayer()

    override fun onMethodCall(                                       // ← OUVERTURE onMethodCall
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {

            // Configuration initiale — appelée une seule fois au démarrage
            // depuis le constructeur RadioService Dart.
            "configure" -> {
                val equalizerEnabled  = call.argument<Boolean>("equalizerEnabled")  ?: true
                val backgroundEnabled = call.argument<Boolean>("backgroundEnabled") ?: true
                player.configure(equalizerEnabled = equalizerEnabled)
                onConfigure(backgroundEnabled)
                result.success(null)
            }
            // URL du flux :
            //   isHls = false : URL du proxy local Dart (http://127.0.0.1:PORT/stream)
            //                   ExoPlayer joue depuis ce proxy via ProgressiveMediaSource
            //   isHls = true  : URL directe du manifest HLS (.m3u8)
            //                   ExoPlayer gère les segments via HlsMediaSource
            "setUrl" -> {
                val url         = call.argument<String>("url")
                val stationName = call.argument<String>("stationName")
                val isHls       = call.argument<Boolean>("isHls") ?: false
                if (url == null) {
                    result.error("INVALID_ARGUMENT", "url is required", null)
                    return
                }
                player.setUrl(url, stationName, isHls, result)
            }

            "play"       -> player.play(result)
            "pause"      -> player.pause(result)
            "stop"       -> player.stop(result)

            // Ajuste le volume entre 0.0 et 1.0
            "setVolume"  -> {
                val volume = call.argument<Double>("volume")
                if (volume == null) {
                    result.error("INVALID_ARGUMENT", "volume is required", null)
                    return
                }
                player.setVolume(volume.toFloat(), result)
            }

            // Déplace la position dans le buffer (time-shift)
            "seek" -> {
                val positionMs = call.argument<Int>("positionMs")
                if (positionMs == null) {
                    result.error("INVALID_ARGUMENT", "positionMs is required", null)
                    return
                }
                player.seek(positionMs.toLong(), result)
            }

            // Retour immédiat au live
            "seekToLive" -> player.seekToLive(result)

            // Met à jour titre/artiste/artwork dans la notification.
            // artworkBytes : bytes de la pochette téléchargée par Dart (pas d'URL)
            "updateMetadata" -> {
                val title        = call.argument<String>("title")
                val artist       = call.argument<String>("artist")
                val artworkBytes = call.argument<ByteArray>("artworkBytes")
                player.updateMediaMetadata(title, artist, artworkBytes, result)
            }

            // Applique les 5 bandes de l'égaliseur
            "setEqualizer" -> {
                val sub    = call.argument<Double>("sub")    ?: 0.0
                val bass   = call.argument<Double>("bass")   ?: 0.0
                val mid    = call.argument<Double>("mid")    ?: 0.0
                val high   = call.argument<Double>("high")   ?: 0.0
                val treble = call.argument<Double>("treble") ?: 0.0
                player.setEqualizer(sub, bass, mid, high, treble, result)
            }

            else -> result.notImplemented()
        }
    }                                                                // ← FERMETURE onMethodCall

    fun dispose() = player.release()

}                                                                    // ← FERMETURE CLASSE