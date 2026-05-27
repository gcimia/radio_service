package com.dev.gcimia.radio_service

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.extractor.metadata.id3.TextInformationFrame
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// Config d'égaliseur en attente quand le player n'est pas encore prêt.
private data class PendingEq(
    val sub:    Double,  //    60 Hz
    val bass:   Double,  //   230 Hz
    val mid:    Double,  //   910 Hz
    val high:   Double,  //  3600 Hz
    val treble: Double,  // 14000 Hz
)

// Wrapper ExoPlayer — gère uniquement la lecture audio et l'égaliseur.
//
// Dans la nouvelle architecture, Dart gère :
//   - la connexion HTTP au flux radio
//   - l'extraction des métadonnées ICY
//   - la transmission des bytes audio via AudioProxyServer
//
// ExoPlayer reçoit uniquement l'URL du proxy local (127.0.0.1:PORT/stream)
// et joue l'audio pur. Il ne remonte aucune métadonnée.
class RadioExoPlayer(                                                // ← OUVERTURE CLASSE
    context: Context,
    private val eventStream: PlayerEventStream,
    private var equalizerEnabled: Boolean = true,                    // ← configurable
) {
    private val appContext        = context.applicationContext
    private val scope             = CoroutineScope(Dispatchers.Main)
    private var positionJob:      Job? = null
    private var radioEqualizer:   RadioEqualizer? = null
    private var pendingEqualizer: PendingEq?      = null

    // MetadataExtractor — utilisé pour les flux HLS uniquement.
    // Pour les flux ICY progressifs, Dart gère les métadonnées via IcyStreamReader.
    // Pour HLS, ExoPlayer remonte les tags ID3 in-band via onMetadata().
    private val metadataExtractor = MetadataExtractor(eventStream)
    // Mémorisé pour que onTracksChanged sache s'il faut affiner la détection
    private var currentIsHls = false

    private var exoPlayer: ExoPlayer = buildPlayer(
        context.applicationContext,
        maxBufferMs = 30 * 60 * 1000,
        minBufferMs = 5_000,
    )

    init {                                                           // ← OUVERTURE init
        attachListener()
    }                                                                // ← FERMETURE init

    // ── Listener ──────────────────────────────────────────────────────────────

    private fun attachListener() {                                   // ← OUVERTURE attachListener
        exoPlayer.addListener(object : Player.Listener {

            override fun onPlaybackStateChanged(state: Int) {
                val mapped = when (state) {
                    Player.STATE_IDLE      -> "idle"
                    Player.STATE_BUFFERING -> "buffering"
                    Player.STATE_READY     -> if (exoPlayer.playWhenReady) "playing" else "paused"
                    Player.STATE_ENDED     -> "stopped"
                    else                   -> "idle"
                }
                eventStream.sendState(mapped)

                if (state == Player.STATE_READY && radioEqualizer == null) {
                    if (equalizerEnabled) {
                        radioEqualizer = RadioEqualizer(exoPlayer.audioSessionId)
                        pendingEqualizer?.let { eq ->
                            radioEqualizer?.apply(eq.sub, eq.bass, eq.mid, eq.high, eq.treble)
                            pendingEqualizer = null
                        }
                    }
                }

                if (state == Player.STATE_READY) startPositionUpdates()
                else stopPositionUpdates()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (exoPlayer.playbackState == Player.STATE_READY) {
                    eventStream.sendState(if (isPlaying) "playing" else "paused")
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                eventStream.sendError(error.message ?: "Unknown playback error")
            }

            // Métadonnées — actif pour les flux HLS uniquement.
            // MetadataExtractor filtre automatiquement selon isProgressiveSource :
            //   - flux HLS  → accept onMetadata() (ID3 in-band des segments .ts/.aac)
            //   - flux ICY  → ignore onMetadata() (Dart gère via IcyStreamReader)
            override fun onMetadata(metadata: androidx.media3.common.Metadata) {
                metadataExtractor.onMetadata(metadata)
            }

            // Métadonnées agrégées par Media3 (titre, artiste, pochette).
            // Pour les flux HLS, Media3 les extrait automatiquement des tags ID3
            // timed metadata et les expose ici. On délègue à MetadataExtractor
            // qui filtre selon isProgressiveSource (ignoré pour les flux ICY).
            override fun onMediaMetadataChanged(
                mediaMetadata: androidx.media3.common.MediaMetadata
            ) {
                metadataExtractor.onMediaMetadata(mediaMetadata)
            }

            // Affine la détection du type de source après que les pistes sont connues.
            // Uniquement pour les flux sans extension .m3u8 (URL ambiguë comme /stream).
            // Si isHls est déjà connu via l'URL, on ne touche pas à isProgressiveSource
            // car le containerMimeType AAC serait mal interprété comme flux progressif.
            override fun onTracksChanged(tracks: androidx.media3.common.Tracks) {
                android.util.Log.d("RadioExoPlayer", "onTracksChanged: currentIsHls=$currentIsHls groups=${tracks.groups.size}")
                if (currentIsHls) return  // déjà identifié HLS via URL → pas d'affinage
                val isProgressive = tracks.groups.any { group ->
                    (0 until group.length).any { i ->
                        val mimeType = group.getTrackFormat(i).containerMimeType ?: ""
                        mimeType.contains("mpeg") || mimeType.contains("aac") ||
                                mimeType.contains("ogg")  || mimeType.contains("opus")
                    }
                }
                metadataExtractor.refineSourceType(isProgressive)
            }
        })
    }                                                                // ← FERMETURE attachListener

    // ── Configuration ─────────────────────────────────────────────────────────

    /// Appelée une seule fois depuis RadioPlayerHandler après l'initialisation.
    /// Permet d'activer/désactiver les fonctionnalités optionnelles.
    fun configure(equalizerEnabled: Boolean) {               // ← OUVERTURE configure
        this.equalizerEnabled = equalizerEnabled
        if (!equalizerEnabled) {
            radioEqualizer?.release()
            radioEqualizer   = null
            pendingEqualizer = null
        }
    }                                                        // ← FERMETURE configure

    // ── Commandes de lecture ───────────────────────────────────────────────────

    // Reçoit l'URL du proxy local Dart (http://127.0.0.1:PORT/stream).
    // ExoPlayer joue depuis ce proxy exactement comme depuis une URL radio.
    fun setUrl(                                                      // ← OUVERTURE setUrl
        url:         String,
        stationName: String?,
        isHls:       Boolean,
        result:      MethodChannel.Result,
    ) {
        stopPositionUpdates()

        radioEqualizer?.release()
        radioEqualizer   = null
        pendingEqualizer = null

        exoPlayer.stop()
        exoPlayer.clearMediaItems()

        android.util.Log.d("RadioExoPlayer", "setUrl: isHls=$isHls url=$url")
        // Mémorise isHls pour que onTracksChanged puisse éviter de l'écraser
        currentIsHls = isHls
        // Réinitialise MetadataExtractor pour le nouveau flux.
        // isHls = true  → accepte onMetadata() et onMediaMetadata() pour les tags ID3 HLS
        // isHls = false → ignore ces callbacks (Dart gère via IcyStreamReader)
        metadataExtractor.reset(isHls = isHls)

        val dataSourceFactory = DefaultHttpDataSource.Factory()
            .setUserAgent("RadioService/1.0 (ExoPlayer)")
            .setConnectTimeoutMs(10_000)
            .setReadTimeoutMs(30_000)

        // Initialise le MediaItem avec le nom de station dès le départ.
        // Évite que la notification affiche un path vide avant les métadonnées.
        val initialMetadata = androidx.media3.common.MediaMetadata.Builder()
            .setTitle(stationName ?: "")
            .setArtist(null)
            .build()

        val mediaItem = MediaItem.Builder()
            .setUri(Uri.parse(url))
            .setMediaMetadata(initialMetadata)
            .build()

        val mediaSource = if (isHls) {
            // ── Flux HLS ───────────────────────────────────────────────────────
            // HlsMediaSource gère le téléchargement des segments .ts/.aac,
            // l'adaptation de bitrate, et la remontée des tags ID3 via onMetadata().
            HlsMediaSource.Factory(dataSourceFactory)
                .createMediaSource(mediaItem)
        } else {
            // ── Flux progressif (ICY) ──────────────────────────────────────────
            // ExoPlayer joue depuis le proxy local Dart (http://127.0.0.1:PORT/stream).
            // Pas de timeout read — streaming continu depuis localhost.
            ProgressiveMediaSource.Factory(
                DefaultHttpDataSource.Factory()
                    .setUserAgent("RadioService/1.0 (ExoPlayer)")
                    .setConnectTimeoutMs(5_000)
                    .setReadTimeoutMs(0),  // 0 = pas de timeout pour le streaming continu
            ).createMediaSource(mediaItem)
        }

        exoPlayer.setMediaSource(mediaSource)
        exoPlayer.prepare()
        result.success(null)
    }                                                                // ← FERMETURE setUrl

    fun play(result: MethodChannel.Result) {                         // ← OUVERTURE play
        exoPlayer.play()
        result.success(null)
    }                                                                // ← FERMETURE play

    fun pause(result: MethodChannel.Result) {                        // ← OUVERTURE pause
        exoPlayer.pause()
        result.success(null)
    }                                                                // ← FERMETURE pause

    fun stop(result: MethodChannel.Result) {                         // ← OUVERTURE stop
        stopPositionUpdates()
        exoPlayer.stop()
        result.success(null)
    }                                                                // ← FERMETURE stop

    fun setVolume(volume: Float, result: MethodChannel.Result) {     // ← OUVERTURE setVolume
        exoPlayer.volume = volume
        result.success(null)
    }                                                                // ← FERMETURE setVolume

    // Seek à une position absolue dans le buffer (time-shift)
    fun seek(positionMs: Long, result: MethodChannel.Result) {       // ← OUVERTURE seek
        val bufferedMs = exoPlayer.bufferedPosition
        val clamped    = positionMs.coerceIn(0L, bufferedMs)
        exoPlayer.seekTo(clamped)
        result.success(null)
    }                                                                // ← FERMETURE seek

    // Retour immédiat au live
    fun seekToLive(result: MethodChannel.Result) {                   // ← OUVERTURE seekToLive
        exoPlayer.seekToDefaultPosition()
        result.success(null)
    }                                                                // ← FERMETURE seekToLive

    // ── Métadonnées notification ───────────────────────────────────────────────

    // Reçoit titre, artiste et pochette depuis Dart pour mettre à jour
    // la notification système et l'écran de verrouillage.
    fun updateMediaMetadata(                                         // ← OUVERTURE updateMediaMetadata
        title:        String?,
        artist:       String?,
        artworkBytes: ByteArray?,   // bytes téléchargés par Dart — pas d'appel réseau ici
        result:       MethodChannel.Result,
    ) {
        // Synchrone — Dart a déjà téléchargé l'image.
        val mediaMetadata = androidx.media3.common.MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(artist)
            .setArtworkData(
                artworkBytes,
                if (artworkBytes != null)
                    androidx.media3.common.MediaMetadata.PICTURE_TYPE_FRONT_COVER
                else null,
            )
            .build()

        exoPlayer.replaceMediaItem(
            0,
            exoPlayer.currentMediaItem
                ?.buildUpon()
                ?.setMediaMetadata(mediaMetadata)
                ?.build()
                ?: run { result.success(null); return },
        )

        result.success(null)
    }                                                                // ← FERMETURE updateMediaMetadata

    // ── Égaliseur ──────────────────────────────────────────────────────────────

    fun setEqualizer(                                                // ← OUVERTURE setEqualizer
        sub:    Double,
        bass:   Double,
        mid:    Double,
        high:   Double,
        treble: Double,
        result: MethodChannel.Result,
    ) {
        if (radioEqualizer != null) {
            radioEqualizer?.apply(sub, bass, mid, high, treble)
        } else {
            pendingEqualizer = PendingEq(sub, bass, mid, high, treble)
        }
        result.success(null)
    }                                                                // ← FERMETURE setEqualizer

    fun resetEqualizer(result: MethodChannel.Result) {               // ← OUVERTURE resetEqualizer
        radioEqualizer?.reset()
        pendingEqualizer = null
        result.success(null)
    }                                                                // ← FERMETURE resetEqualizer

    // ── Accès externe ──────────────────────────────────────────────────────────

    fun getExoPlayer(): ExoPlayer = exoPlayer

    fun release() {                                                  // ← OUVERTURE release
        stopPositionUpdates()
        radioEqualizer?.release()
        exoPlayer.release()
    }                                                                // ← FERMETURE release

    // ── Position ───────────────────────────────────────────────────────────────

    private fun startPositionUpdates() {                             // ← OUVERTURE startPositionUpdates
        positionJob?.cancel()
        positionJob = scope.launch {
            while (true) {
                val currentMs   = exoPlayer.currentPosition
                val bufferedMs  = exoPlayer.bufferedPosition
                val bufferDepth = bufferedMs - currentMs
                val isLive      = bufferDepth < 5_000

                if (isLive) {
                    eventStream.sendPosition(isLive = true)
                } else {
                    eventStream.sendPosition(
                        isLive        = false,
                        currentMs     = currentMs,
                        bufferStartMs = 0L,
                        bufferEndMs   = bufferedMs,
                    )
                }
                delay(1_000)
            }
        }
    }                                                                // ← FERMETURE startPositionUpdates

    private fun stopPositionUpdates() {                              // ← OUVERTURE stopPositionUpdates
        positionJob?.cancel()
        positionJob = null
    }                                                                // ← FERMETURE stopPositionUpdates

    // ── Construction du player ─────────────────────────────────────────────────

    private fun buildPlayer(                                         // ← OUVERTURE buildPlayer
        context:     Context,
        maxBufferMs: Int,
        minBufferMs: Int,
    ): ExoPlayer {
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                minBufferMs,
                maxBufferMs,
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_MS,
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
            )
            .build()

        return ExoPlayer.Builder(context)
            .setLoadControl(loadControl)
            // ── Session audio ──────────────────────────────────────────────
            // Audio focus — Media3 gère automatiquement :
            //   - Pause lors d'un appel téléphonique entrant
            //   - Reprise après l'appel si la lecture était en cours
            //   - Ducking (baisse du volume) quand une autre appli joue
            .setAudioAttributes(
                androidx.media3.common.AudioAttributes.Builder()
                    .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                    .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ true,
            )
            // Becoming noisy — pause automatique quand :
            //   - le casque filaire est débranché
            //   - la connexion Bluetooth audio se coupe
            .setHandleAudioBecomingNoisy(true)
            .build()
    }                                                                // ← FERMETURE buildPlayer

}                                                                    // ← FERMETURE CLASSE