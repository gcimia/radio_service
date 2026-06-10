package com.dev.gcimia.radio_service

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build

/**
 * Gère le focus audio manuellement (côté ExoPlayer : handleAudioFocus=false).
 *
 * On reprend la main sur le focus pour pouvoir offrir le choix
 * reprise automatique / reprise manuelle après une interruption — ce que
 * `handleAudioFocus=true` de Media3 ne permet pas (il reprend toujours).
 *
 * Comportement (calqué sur audio_service) :
 *   - perte permanente (AUDIOFOCUS_LOSS)            → pause, pas de reprise auto
 *   - perte transitoire (AUDIOFOCUS_LOSS_TRANSIENT) → pause, reprise auto au retour si [autoResume]
 *   - duckable (…_CAN_DUCK : notif courte, GPS)     → baisse le volume, restaure au retour
 *   - retour du focus (AUDIOFOCUS_GAIN)             → restaure le volume ; reprend si applicable
 */
class RadioAudioFocusManager(
    context: Context,
    private val onPause:  () -> Unit,   // mettre en pause (perte de focus)
    private val onResume: () -> Unit,   // reprendre la lecture (focus regagné)
    private val onDuck:   () -> Unit,   // baisser le volume (ducking)
    private val onUnduck: () -> Unit,   // restaurer le volume
) {
    private val audioManager =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** Reprise auto après une interruption transitoire. Modifiable via configure(). */
    var autoResume: Boolean = true

    // Vrai si la pause courante provient d'une perte de focus transitoire
    // (donc candidate à la reprise auto). Faux pour une pause utilisateur.
    private var pausedByTransientLoss = false

    private var focusRequest: AudioFocusRequest? = null  // API 26+

    private val listener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Perte définitive (une autre appli média a pris le focus).
                pausedByTransientLoss = false
                onPause()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Interruption temporaire (appel…). Reprise possible au retour.
                pausedByTransientLoss = true
                onPause()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // Notif courte / voix GPS — on baisse le volume sans couper.
                onDuck()
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                onUnduck()
                if (pausedByTransientLoss) {
                    pausedByTransientLoss = false
                    if (autoResume) onResume()
                    // sinon : reste en pause → reprise manuelle par l'utilisateur
                }
            }
        }
    }

    /** Demande le focus. Retourne true si accordé. À appeler avant de jouer. */
    fun request(): Boolean {
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setWillPauseWhenDucked(false)  // on gère le ducking nous-mêmes
                .setOnAudioFocusChangeListener(listener)
                .build()
            focusRequest = req
            audioManager.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                listener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    /** Abandonne le focus (pause/stop utilisateur, ou release). */
    fun abandon() {
        pausedByTransientLoss = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(listener)
        }
    }
}
