package com.dev.gcimia.radio_service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.media.audiofx.AudioEffect
import android.net.Uri
import android.os.Build
import androidx.core.content.ContextCompat
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
    // Déléguer au panneau du constructeur. Défaut `true` : voir RadioService.
    private var preferSystemEqualizer: Boolean = true,
) {
    private val appContext        = context.applicationContext
    private val scope             = CoroutineScope(Dispatchers.Main)
    private var positionJob:      Job? = null
    private var radioEqualizer:   RadioEqualizer? = null
    // Réglage reçu avant que le player soit prêt — consommé à STATE_READY.
    private var pendingEqualizer: PendingEq?      = null
    // Dernier réglage demandé, qui SURVIT aux changements de station.
    // setUrl() libère l'égaliseur (nouvelle session audio, nouvel audioSessionId) ;
    // sans cette mémoire, le réglage était perdu à chaque changement de radio et
    // l'hôte devait le renvoyer après chaque chargement pour qu'il tienne.
    private var lastEqualizer:    PendingEq?      = null

    // MetadataExtractor — utilisé pour les flux HLS uniquement.
    // Pour les flux ICY progressifs, Dart gère les métadonnées via IcyStreamReader.
    // Pour HLS, ExoPlayer remonte les tags ID3 in-band via onMetadata().
    private val metadataExtractor = MetadataExtractor(eventStream)
    // Mémorisé pour que onTracksChanged sache s'il faut affiner la détection
    private var currentIsHls = false

    // Vrai entre une erreur de lecture et le prochain setUrl. Sert à ne pas
    // émettre le STATE_IDLE automatique qu'ExoPlayer génère juste après une
    // erreur — sinon cet "idle" écrase le message d'erreur côté UI (« Arrêté »
    // au lieu de « Erreur »).
    private var inErrorState = false

    // Évite une double libération (le service ET le handler peuvent appeler release()).
    private var released = false

    private var exoPlayer: ExoPlayer = buildPlayer(
        context.applicationContext,
        maxBufferMs = 30 * 60 * 1000,
        minBufferMs = 5_000,
    )

    // Volume « voulu » par l'app (hors ducking). Sert à restaurer après un duck.
    private var currentVolume = 1.0f

    // Gestion manuelle du focus audio (ExoPlayer construit avec
    // handleAudioFocus=false). Permet la pause sur audio entrant + le choix
    // reprise auto / manuelle.
    //
    // onPause         : interruption TRANSITOIRE (appel entrant). La source
    //                   Dart reste en place — une reprise auto doit être
    //                   instantanée, et une reconnexion la rendrait impossible.
    // onPermanentLoss : perte DÉFINITIVE du focus. Traitée comme une pause
    //                   explicite : Dart relâche la source.
    private val focusManager = RadioAudioFocusManager(
        context.applicationContext,
        onPause         = { exoPlayer.pause() },
        onResume        = { exoPlayer.play() },
        onDuck          = { exoPlayer.volume = currentVolume * 0.2f },
        onUnduck        = { exoPlayer.volume = currentVolume },
        onPermanentLoss = { externalPause("focusLoss") },
    )

    // ── Routage de l'égalisation ──────────────────────────────────────────────
    //
    // Beaucoup d'appareils ont déjà leur égaliseur : plus de bandes, accordé
    // pour leur haut-parleur, et réglé avec la bonne marge. Empiler le nôtre
    // par-dessus donne deux traitements en série, et le bundle d'effets
    // standard d'Android retranche en prime une marge proportionnelle au gain
    // positif demandé — d'où des renforcements qui s'entendent comme des
    // atténuations. Quand l'appareil sait mieux faire, on lui laisse la place.
    //
    // La détection ne regarde PAS la marque : elle demande au système si une
    // activité répond au panneau d'effets audio. C'est une question sur une
    // capacité, elle vieillit bien.
    private fun systemPanelIntent(): Intent =
        Intent(AudioEffect.ACTION_DISPLAY_AUDIO_EFFECT_CONTROL_PANEL)
            .putExtra(AudioEffect.EXTRA_AUDIO_SESSION, exoPlayer.audioSessionId)
            .putExtra(AudioEffect.EXTRA_PACKAGE_NAME, appContext.packageName)
            .putExtra(AudioEffect.EXTRA_CONTENT_TYPE, AudioEffect.CONTENT_TYPE_MUSIC)

    // queryIntentActivities plutôt que resolveActivity : quand plusieurs
    // activités répondent, resolveActivity rend l'activité de choix du système
    // — ou null — alors qu'on veut seulement savoir si QUELQUE CHOSE répond.
    //
    // Le résultat est journalisé : s'il sort vide sur un appareil qui a
    // visiblement un égaliseur, c'est la déclaration <queries> du manifeste qui
    // manque (voir AndroidManifest.xml), pas l'appareil qui en est dépourvu.
    // Résultat mémorisé : il ne dépend que des paquets installés et des champs
    // Build, qui ne bougent pas en cours de processus. Sans ça, la requête au
    // PackageManager repartait à chaque appel d'equalizerBackend() — donc à
    // chaque STATE_READY, c'est-à-dire à chaque changement de station — et la
    // ligne de log se répétait, ce qui se voyait dans la sortie logcat.
    private var systemPanelFound: Boolean? = null

    private fun hasSystemPanel(): Boolean =
        systemPanelFound ?: resolveSystemPanel().also { systemPanelFound = it }

    private fun resolveSystemPanel(): Boolean = runCatching {
        val matches = appContext.packageManager
            .queryIntentActivities(systemPanelIntent(), 0)
            .filter { info ->
                val a = info.activityInfo ?: return@filter false
                // Une activité de NOTRE propre paquet n'est pas « le panneau du
                // téléphone » ; et une activité désactivée ne s'ouvrira pas.
                a.packageName != appContext.packageName && a.enabled && a.exported
            }

        matches.forEach {
            android.util.Log.d("RadioExoPlayer",
                "panneau système — ${it.activityInfo?.packageName}" +
                        "/${it.activityInfo?.name}")
        }
        if (matches.isEmpty()) {
            android.util.Log.d("RadioExoPlayer",
                "panneau système — aucune activité exploitable ne répond")
        }

        // ATTENTION : répondre à l'intent ne prouve pas que le panneau FONCTIONNE.
        // Certaines images système — l'émulateur notamment — exposent une
        // activité qui s'ouvre et se referme aussitôt sans rien régler, et rien
        // dans l'API ne permet de le savoir à l'avance. C'est pourquoi
        // useBuiltInEqualizer() existe : la détection est au mieux une
        // présomption, l'hôte doit pouvoir la démentir à l'exécution.
        matches.isNotEmpty()
    }.getOrElse {
        android.util.Log.w("RadioExoPlayer", "détection du panneau — ${it.message}")
        false
    }

    /// Dément la détection : bascule DÉFINITIVEMENT sur l'égaliseur du plugin
    /// pour cette session, et l'attache tout de suite si la lecture est en cours.
    ///
    /// Existe parce qu'aucune API ne dit si le panneau du constructeur fait
    /// réellement quelque chose. Quand il s'avère inopérant, c'est la seule
    /// porte de sortie — sinon l'utilisateur reste avec un bouton qui n'agit
    /// sur rien et sans curseurs pour le remplacer.
    fun useBuiltInEqualizer(result: MethodChannel.Result) {
        preferSystemEqualizer = false
        android.util.Log.d("RadioExoPlayer",
            "égaliseur — bascule forcée sur le plugin (backend ${equalizerBackend()})")

        if (radioEqualizer == null && equalizerBackend() == "plugin" &&
            exoPlayer.audioSessionId != androidx.media3.common.C.AUDIO_SESSION_ID_UNSET
        ) {
            radioEqualizer = RadioEqualizer(exoPlayer.audioSessionId)
            lastEqualizer?.let { eq ->
                radioEqualizer?.apply(eq.sub, eq.bass, eq.mid, eq.high, eq.treble)
            }
        }
        result.success(null)
    }

    // Environnements dont on SAIT que le panneau d'égaliseur est factice.
    //
    // Il n'existe aucune API officielle pour distinguer un émulateur d'un
    // téléphone — Android Studio lui-même lit ces mêmes propriétés Build via
    // adb. On s'en tient donc aux signaux stables et documentés, et seulement
    // à ceux-là : ce n'est pas un contrôle de sécurité (il se contourne
    // trivialement, et ce n'est pas le but), juste de quoi éviter un bouton
    // mort en développement.
    //
    // Limite assumée : un émulateur exotique non reconnu passera au travers et
    // retombera sur le comportement précédent. useBuiltInEqualizer() reste
    // alors la porte de sortie.
    private fun looksLikeEmulator(): Boolean {
        val hardware     = Build.HARDWARE.lowercase()
        val fingerprint  = Build.FINGERPRINT.lowercase()
        val product      = Build.PRODUCT.lowercase()
        val model        = Build.MODEL.lowercase()
        val device       = Build.DEVICE.lowercase()

        return hardware in setOf("goldfish", "ranchu", "vbox86", "android_x86")
                || fingerprint.startsWith("generic")
                || fingerprint.startsWith("unknown")
                || fingerprint.contains("emulator")
                || fingerprint.contains("vbox")
                || product.contains("sdk")
                || product.contains("emulator")
                || product.contains("simulator")
                || model.contains("emulator")
                || model.contains("android sdk built for")
                // Build.DEVICE des AVD récents : emu64xa, emu64a, emu64x…
                || device.startsWith("emu")
                || device.startsWith("generic")
                || Build.MANUFACTURER.contains("Genymotion", ignoreCase = true)
    }

    // Les quatre champs sur lesquels Media3 s'identifie lui-même, dans le même
    // ordre, plus les deux que la détection utilise en propre.
    //
    // Objectif : qu'un appareil passé au travers de looksLikeEmulator() se
    // diagnostique tout seul. Le log dit exactement quelles valeurs ont été
    // lues — il suffit de les comparer à la liste des signaux ci-dessus pour
    // savoir lequel ajouter, sans avoir à instrumenter quoi que ce soit.
    private fun deviceDebugInfo(): String =
        "[${Build.DEVICE}, ${Build.MODEL}, ${Build.MANUFACTURER}, ${Build.VERSION.SDK_INT}]" +
                " hardware=${Build.HARDWARE} product=${Build.PRODUCT}"


    /// "system", "plugin" ou "unavailable:<raison>" — lu par Dart après configure.
    fun equalizerBackend(): String = when {
        !equalizerEnabled      -> "unavailable:égaliseur désactivé à la construction"
        !preferSystemEqualizer -> "plugin"
        // Le panneau de l'émulateur répond à l'intent mais s'ouvre et se
        // referme sans rien régler : on ne lui délègue pas.
        looksLikeEmulator()    -> "plugin"
        hasSystemPanel()       -> "system"
        else                   -> "plugin"
    }

    fun openSystemEqualizer(result: MethodChannel.Result) {
        val intent = systemPanelIntent().addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { appContext.startActivity(intent) }
            .onSuccess { result.success(null) }
            .onFailure {
                android.util.Log.w("RadioExoPlayer",
                    "panneau système introuvable — ${it.message}")
                result.error("NO_PANEL", it.message, null)
            }
    }

    // Déclare notre session au système, pour que SON égaliseur s'applique à
    // NOTRE flux et non à un réglage global. Ouvrir le panneau ne suffit pas :
    // sans ces deux diffusions, le panneau peut éditer quelque chose qui ne
    // nous concerne pas. À appeler en paire — ouverture à la session, fermeture
    // à la libération, sinon le système garde une session fantôme.
    private var sessionDeclared = false

    private fun broadcastSession(open: Boolean) {
        val action = if (open) {
            AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION
        } else {
            AudioEffect.ACTION_CLOSE_AUDIO_EFFECT_CONTROL_SESSION
        }
        if (open == sessionDeclared) return
        runCatching {
            appContext.sendBroadcast(
                Intent(action)
                    .putExtra(AudioEffect.EXTRA_AUDIO_SESSION, exoPlayer.audioSessionId)
                    .putExtra(AudioEffect.EXTRA_PACKAGE_NAME, appContext.packageName)
                    .putExtra(AudioEffect.EXTRA_CONTENT_TYPE, AudioEffect.CONTENT_TYPE_MUSIC),
            )
            sessionDeclared = open
            android.util.Log.d("RadioExoPlayer",
                "session ${if (open) "déclarée" else "retirée"} auprès du système" +
                        " (id ${exoPlayer.audioSessionId})")
        }
    }

    // ── Casque débranché ──────────────────────────────────────────────────────
    //
    // ExoPlayer sait se mettre en pause seul sur ACTION_AUDIO_BECOMING_NOISY
    // (setHandleAudioBecomingNoisy), mais il le fait SANS prévenir Dart. La
    // couche réseau Dart gardait alors sa connexion amont ouverte pour un
    // lecteur qui ne lit plus : elle finissait par expirer, puis se reconnectait
    // en boucle (PlayerInterrupted) sans qu'aucun geste n'en sorte — il fallait
    // fermer l'application. On reprend donc la main : même geste, Dart prévenu.
    private var noisyRegistered = false

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                externalPause("noisy")
            }
        }
    }

    private fun registerNoisy() {
        if (noisyRegistered) return
        // ContextCompat impose le drapeau d'export, obligatoire depuis
        // Android 14 (API 34) : un registerReceiver() sans drapeau y lève.
        ContextCompat.registerReceiver(
            appContext,
            noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        noisyRegistered = true
    }

    private fun unregisterNoisy() {
        if (!noisyRegistered) return
        runCatching { appContext.unregisterReceiver(noisyReceiver) }
        noisyRegistered = false
    }

    // Pause venue de l'EXTÉRIEUR : casque débranché, perte définitive du focus.
    // Même effet qu'une pause utilisateur côté natif, plus un événement pour que
    // Dart relâche la source comme le ferait PlayerController.pause().
    private fun externalPause(reason: String) {
        android.util.Log.d("RadioExoPlayer", "externalPause — $reason")
        unregisterNoisy()
        exoPlayer.pause()
        focusManager.abandon()
        eventStream.sendExternalPause(reason)
    }

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
                // Après une erreur, ExoPlayer repasse en STATE_IDLE : on n'émet
                // pas cet "idle" automatique, sinon il écrase le PlayerError
                // affiché par l'UI. L'état reste « Erreur » jusqu'au prochain setUrl.
                if (!(state == Player.STATE_IDLE && inErrorState)) {
                    eventStream.sendState(mapped)
                }

                // L'effet n'est instancié QUE si l'égalisation nous revient.
                // Le créer alors qu'on délègue au panneau du constructeur
                // remettrait deux égaliseurs en série — exactement ce que le
                // routage sert à éviter.
                // La session audio n'a d'identifiant valide qu'une fois le
                // rendu audio initialisé — donc ici, et pas au configure.
                // C'est aussi pour ça que l'égaliseur est créé à cet endroit.
                if (state == Player.STATE_READY) broadcastSession(open = true)

                if (state == Player.STATE_READY && radioEqualizer == null) {
                    if (equalizerBackend() == "plugin") {
                        radioEqualizer = RadioEqualizer(exoPlayer.audioSessionId)
                        // En attente d'abord, à défaut le dernier réglage connu :
                        // c'est ce qui fait tenir l'égaliseur d'une station à l'autre.
                        (pendingEqualizer ?: lastEqualizer)?.let { eq ->
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
                inErrorState = true
                eventStream.sendErrorState(error.message ?: "Unknown playback error")
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
    fun configure(                                                   // ← OUVERTURE configure
        equalizerEnabled: Boolean,
        autoResume: Boolean = true,
        preferSystemEqualizer: Boolean = true,
    ) {
        this.equalizerEnabled       = equalizerEnabled
        this.preferSystemEqualizer  = preferSystemEqualizer
        focusManager.autoResume     = autoResume

        // Décidé ici, une fois : c'est le moment où l'on sait ce que l'hôte
        // veut ET ce que l'appareil propose.
        // La détection du panneau ne dépend pas de la session : resolveActivity
        // ne regarde que l'action de l'intent. On peut donc décider ici.
        android.util.Log.d("RadioExoPlayer", "appareil — ${deviceDebugInfo()}")
        if (looksLikeEmulator()) {
            android.util.Log.d("RadioExoPlayer",
                "environnement d'émulation détecté — pas de délégation au panneau système")
        }
        android.util.Log.d("RadioExoPlayer", "égaliseur — backend ${equalizerBackend()}")
        if (!equalizerEnabled) {
            // Fonctionnalité coupée : on libère la ressource DSP et on oublie
            // le réglage — le rallumer plus tard doit repartir de plat.
            radioEqualizer?.release()
            radioEqualizer   = null
            pendingEqualizer = null
            lastEqualizer    = null
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
        // Nouveau flux → on lève le verrou d'erreur (les états idle/buffering
        // redeviennent significatifs).
        inErrorState = false

        stopPositionUpdates()

        // L'égaliseur est lié à l'audioSessionId, qui change avec le flux :
        // on le libère. `lastEqualizer` n'est volontairement PAS effacé — il
        // sera réappliqué à STATE_READY sur la nouvelle session.
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
        // Demande le focus audio (enregistre aussi le listener pour réagir
        // aux interruptions). On lance la lecture même si refusé (intention
        // utilisateur explicite) — le refus reste rarissime.
        focusManager.request()
        registerNoisy()
        exoPlayer.play()
        result.success(null)
    }                                                                // ← FERMETURE play

    fun pause(result: MethodChannel.Result) {                        // ← OUVERTURE pause
        // Pause demandée par l'utilisateur → on relâche le focus.
        unregisterNoisy()
        exoPlayer.pause()
        focusManager.abandon()
        result.success(null)
    }                                                                // ← FERMETURE pause

    fun stop(result: MethodChannel.Result) {                         // ← OUVERTURE stop
        stopPositionUpdates()
        unregisterNoisy()
        exoPlayer.stop()
        focusManager.abandon()
        result.success(null)
    }                                                                // ← FERMETURE stop

    fun setVolume(volume: Float, result: MethodChannel.Result) {     // ← OUVERTURE setVolume
        currentVolume    = volume
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
        val eq = PendingEq(sub, bass, mid, high, treble)
        lastEqualizer = eq
        if (radioEqualizer != null) {
            radioEqualizer?.apply(sub, bass, mid, high, treble)
        } else {
            pendingEqualizer = eq
        }
        result.success(null)
    }                                                                // ← FERMETURE setEqualizer

    fun resetEqualizer(result: MethodChannel.Result) {               // ← OUVERTURE resetEqualizer
        radioEqualizer?.reset()
        pendingEqualizer = null
        lastEqualizer    = null
        result.success(null)
    }                                                                // ← FERMETURE resetEqualizer

    // ── Accès externe ──────────────────────────────────────────────────────────

    fun getExoPlayer(): ExoPlayer = exoPlayer

    fun release() {                                                  // ← OUVERTURE release
        if (released) return
        released = true
        stopPositionUpdates()
        unregisterNoisy()
        broadcastSession(open = false)
        focusManager.abandon()
        radioEqualizer?.release()
        radioEqualizer   = null
        pendingEqualizer = null
        lastEqualizer    = null
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
            // Focus audio géré MANUELLEMENT par RadioAudioFocusManager
            // (handleAudioFocus=false) afin d'offrir le choix reprise
            // auto / manuelle après une interruption.
            .setAudioAttributes(
                androidx.media3.common.AudioAttributes.Builder()
                    .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                    .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
                    .build(),
                /* handleAudioFocus = */ false,
            )
            // Becoming noisy — géré MANUELLEMENT (voir noisyReceiver) :
            // ExoPlayer sait le faire seul, mais il met en pause sans prévenir
            // Dart, qui laissait alors sa source ouverte pour rien.
            .setHandleAudioBecomingNoisy(false)
            .build()
    }                                                                // ← FERMETURE buildPlayer

}                                                                    // ← FERMETURE CLASSE