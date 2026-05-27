package com.dev.gcimia.radio_service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaStyleNotificationHelper
import androidx.core.app.NotificationCompat

// Gère le canal de notification et la construction de la notification media.
//
// Deux usages :
//   1. RadioNotificationManager(context) → depuis RadioServicePlugin :
//      crée uniquement le canal (pas de mediaSession)
//   2. RadioNotificationManager(context, session) → depuis RadioMediaService :
//      crée le canal + peut construire la notification MediaStyle complète
//      (titre, artiste, pochette, bouton play/pause depuis le MediaItem courant)
@UnstableApi
class RadioNotificationManager(
    private val context:      Context,
    private val mediaSession: MediaSession? = null,
) {
    companion object {
        const val CHANNEL_ID      = "radio_service_playback"
        const val NOTIFICATION_ID = 1001
    }

    init {
        createNotificationChannel()
    }

    // Crée le canal Android 8+ — IMPORTANCE_LOW, pas de son, pas de badge.
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Lecture radio",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description  = "Contrôles de lecture audio"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    // Construit la notification MediaStyle.
    // MediaStyle lit automatiquement depuis le MediaItem courant d'ExoPlayer :
    //   - MediaMetadata.title    → ligne principale
    //   - MediaMetadata.artist   → ligne secondaire
    //   - MediaMetadata.artworkData → image de fond / large icône
    // Et affiche le bouton play/pause selon l'état du player.
    //
    // Retourne null si la mediaSession n'est pas disponible.
    fun buildNotification(): NotificationCompat.Builder? {
        val session = mediaSession ?: return null
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setStyle(
                MediaStyleNotificationHelper.MediaStyle(session)
                    // Action 0 = play/pause ajouté automatiquement par Media3
                    .setShowActionsInCompactView(0)
            )
    }
}