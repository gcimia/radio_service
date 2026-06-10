package com.dev.gcimia.radio_service

import android.app.Notification
import android.content.Intent
import android.os.Build
import androidx.core.app.ServiceCompat
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

// Service qui maintient la lecture audio en arrière-plan.
// Hérite de MediaSessionService — Media3 gère automatiquement :
//   - l'intégration écran de verrouillage
//   - les commandes Bluetooth / casque / Android Auto
//
// La notification est construite par RadioNotificationManager (MediaStyle)
// et rafraîchie manuellement à chaque changement d'état ou de métadonnées.
// C'est l'approche la plus fiable : on garde le contrôle total de la notification
// sans dépendre du timing interne de DefaultMediaNotificationProvider.
@UnstableApi
class RadioMediaService : MediaSessionService() {

    private var mediaSession:       MediaSession?              = null
    private var notificationManager: RadioNotificationManager? = null

    companion object {
        var sharedPlayer: ExoPlayer? = null
    }

    override fun onCreate() {
        super.onCreate()

        val player = sharedPlayer ?: ExoPlayer.Builder(this).build()

        mediaSession = MediaSession.Builder(this, player).build()

        notificationManager = mediaSession?.let { RadioNotificationManager(this, it) }

        // Rafraîchit la notification uniquement sur changement de métadonnées.
        //
        // On n'écoute PAS onIsPlayingChanged ni onPlaybackStateChanged car :
        //   - updateMediaMetadata() télécharge la pochette de façon asynchrone (~3-5s)
        //   - pendant ce téléchargement, ces callbacks declencheraient updateNotification()
        //   - qui lirait le MediaItem AVANT que replaceMediaItem() soit terminé
        //   - effaçant la pochette pendant quelques secondes
        //
        // Le bouton play/pause est géré automatiquement par MediaStyle(session) —
        // il lit l'état du player directement sans avoir besoin de nm.notify().
        player.addListener(object : Player.Listener {

            // Déclenché quand titre/artiste/pochette changent dans le MediaItem.
            // C'est ici qu'on rafraîchit la notification — updateMediaMetadata()
            // dans RadioExoPlayer appelle replaceMediaItem() APRÈS avoir téléchargé
            // la pochette, donc onMediaMetadataChanged arrive toujours avec l'image.
            override fun onMediaMetadataChanged(
                mediaMetadata: androidx.media3.common.MediaMetadata
            ) = updateNotification()

            // play/pause — MediaStyle(session) met à jour le bouton automatiquement
            // via la MediaSession sans besoin de nm.notify(). On ne l'appelle pas ici
            // pour éviter de reconstruire la notification pendant qu'une pochette
            // est en cours de téléchargement (replaceMediaItem pas encore terminé).
        })

        // Démarre le foreground service avec la notification initiale.
        // Android exige cet appel dans les 5 secondes après startForegroundService().
        //
        // ServiceCompat.startForeground() gère les différences d'API :
        //   API 24-28 : startForeground(id, notification) — sans foregroundServiceType
        //   API 29+   : startForeground(id, notification, foregroundServiceType) — requis
        //               pour les services audio (ForegroundServiceStartNotAllowedException sinon)
        ServiceCompat.startForeground(
            /* service   = */ this,
            /* id        = */ RadioNotificationManager.NOTIFICATION_ID,
            /* notification = */ notificationManager?.buildNotification()?.build()
                ?: buildFallbackNotification(),
            /* foregroundServiceType = */ if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            } else {
                0
            },
        )
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? {
        return mediaSession
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Balayage depuis les récents = fermeture explicite de l'appli.
        // On arrête la lecture et on libère le service (→ onDestroy).
        // (Le bouton Home, lui, ne déclenche PAS onTaskRemoved : la lecture
        //  continue normalement en arrière-plan.)
        mediaSession?.player?.stop()
        stopSelf()
    }

    override fun onDestroy() {
        mediaSession?.run {
            player.release()
            release()
            mediaSession = null
        }
        sharedPlayer = null
        super.onDestroy()
    }

    // Reconstruit et publie la notification via NotificationManager.
    // Appelé à chaque événement player significatif.
    private fun updateNotification() {
        val notification = notificationManager?.buildNotification()?.build() ?: return
        val nm = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        nm.notify(RadioNotificationManager.NOTIFICATION_ID, notification)
    }

    // Notification de secours si RadioNotificationManager n'est pas encore prêt.
    private fun buildFallbackNotification(): Notification {
        return androidx.core.app.NotificationCompat.Builder(
            this, RadioNotificationManager.CHANNEL_ID,
        )
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Radio")
            .setSilent(true)
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_LOW)
            .build()
    }
}