package com.dev.gcimia.radio_service

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

// Pont unique entre le lecteur natif et Flutter.
// Thread-safe — garantit l'envoi depuis le main thread.
class PlayerEventStream : EventChannel.StreamHandler {

    private var sink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // Exécute sur le main thread — requis par Flutter EventSink
    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block()
        else mainHandler.post(block)
    }

    fun sendState(state: String) {
        runOnMain {
            sink?.success(mapOf("type" to "state", "value" to state))
        }
    }

    fun sendRawMetadata(source: String, data: Map<String, Any>) {
        runOnMain {
            sink?.success(mapOf("type" to "metadata", "source" to source) + data)
        }
    }

    // Position dans le buffer — émise chaque seconde par RadioExoPlayer
    fun sendPosition(
        isLive:       Boolean,
        currentMs:    Long = 0L,
        bufferStartMs:Long = 0L,
        bufferEndMs:  Long = 0L,
    ) {
        runOnMain {
            sink?.success(mapOf(
                "type"          to "position",
                "isLive"        to isLive,
                "currentMs"     to currentMs,
                "bufferStartMs" to bufferStartMs,
                "bufferEndMs"   to bufferEndMs,
            ))
        }
    }

    // Erreur de lecture émise comme ÉTAT (event de données), pas comme erreur
    // de canal. Ainsi elle arrive côté Dart via onData et devient un PlayerError
    // exploitable par l'UI (au lieu de partir dans onError du stream et d'être
    // ignorée, ce qui laissait le loader tourner indéfiniment).
    fun sendErrorState(message: String) {
        runOnMain {
            sink?.success(mapOf("type" to "state", "value" to "error", "message" to message))
        }
    }
}