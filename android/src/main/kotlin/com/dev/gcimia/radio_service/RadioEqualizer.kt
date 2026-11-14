package com.dev.gcimia.radio_service

import android.media.audiofx.AudioEffect
import android.media.audiofx.Equalizer
import kotlin.math.log10

// Gère l'égaliseur audio natif Android.
// S'attache au flux ExoPlayer via l'audioSessionId.
//
// Dart envoie TOUJOURS cinq gains, pour cinq fréquences nominales :
//   60 Hz (sous-basses), 230 Hz (basses), 910 Hz (médiums),
//   3600 Hz (hauts médiums), 14000 Hz (aigus).
//
// Mais le nombre de bandes de l'appareil et leurs fréquences centrales ne sont
// PAS garantis : selon le téléphone, l'égaliseur système en expose 3, 5, 6, 8
// ou 10, centrées ailleurs. L'ancienne implémentation posait `gains[i]` sur la
// bande matérielle `i` : sur un appareil à 10 bandes, le gain « sous-basses »
// atterrissait sur une bande médium et les cinq bandes restantes étaient
// forcées à 0 — un filtre passe-bas involontaire.
//
// On interpole donc les cinq gains sur la fréquence centrale RÉELLE de chaque
// bande, en échelle logarithmique parce que c'est ainsi que l'oreille perçoit
// les hauteurs. Sur un appareil qui expose exactement les cinq fréquences
// nominales, l'interpolation rend les valeurs d'entrée à l'identique : la
// correction ne change rien là où ça marchait déjà.
//
// La plage matérielle est typiquement [-1500, +1500] milliBels = ±15 dB, mais
// elle est lue sur l'appareil et non supposée.
class RadioEqualizer(audioSessionId: Int) {                          // ← OUVERTURE CLASSE

    private var equalizer: Equalizer? = null

    // Fréquences nominales des cinq curseurs envoyés par Dart, en Hz.
    // Strictement croissantes — l'interpolation en dépend.
    private val sourceHz = doubleArrayOf(60.0, 230.0, 910.0, 3600.0, 14000.0)

    init {                                                           // ← OUVERTURE init
        try {
            android.util.Log.d("RadioEqualizer",
                "init — audioSessionId = $audioSessionId")

            equalizer = Equalizer(0, audioSessionId).apply {
                enabled = true
            }
            logDeviceProfile(audioSessionId)
        } catch (e: Exception) {
            android.util.Log.e("RadioEqualizer", "init failed — ${e.message}")
            equalizer = null
        }
    }                                                                // ← FERMETURE init

    // Applique les cinq gains reçus (en dB, dans [-15, +15]) aux bandes RÉELLES
    // de l'appareil : chaque bande matérielle reçoit le gain interpolé à SA
    // fréquence centrale. Conversion : 1 dB = 100 mB.
    fun apply(                                                       // ← OUVERTURE apply
        sub:    Double,  //    60 Hz
        bass:   Double,  //   230 Hz
        mid:    Double,  //   910 Hz
        high:   Double,  //  3600 Hz
        treble: Double,  // 14000 Hz
    ) {
        val eq = equalizer ?: run {
            android.util.Log.w("RadioEqualizer",
                "apply() — equalizer is null, skipping")
            return
        }

        val bandCount = eq.numberOfBands.toInt()
        if (bandCount == 0) return

        android.util.Log.d("RadioEqualizer",
            "apply — sub=$sub bass=$bass mid=$mid high=$high treble=$treble")

        val gains = doubleArrayOf(sub, bass, mid, high, treble)
        val (minLevel, maxLevel) = eq.bandLevelRange

        for (i in 0 until bandCount) {
            // getCenterFreq rend des milliHertz — d'où la division par 1000.
            val centerHz = eq.getCenterFreq(i.toShort()) / 1000.0
            val gainDb   = interpolate(centerHz, gains)

            val clamped = (gainDb * 100).toInt().coerceIn(
                minLevel.toInt(),
                maxLevel.toInt(),
            ).toShort()

            android.util.Log.d("RadioEqualizer",
                "band $i — ${centerHz.toInt()} Hz — " +
                        "${"%.1f".format(gainDb)} dB — clamped=${clamped}mB")

            eq.setBandLevel(i.toShort(), clamped)
        }

        // RELECTURE — ce que l'appareil a réellement retenu peut différer de ce
        // qu'on a écrit : quantification, borne, ou implémentation constructeur.
        // C'est le seul moyen, sans micro ni mesure, de distinguer « le plugin
        // demande mal » de « l'appareil fait autre chose de la demande ».
        val readBack = (0 until bandCount).joinToString(" ") { i ->
            "${eq.getBandLevel(i.toShort())}"
        }
        android.util.Log.d("RadioEqualizer",
            "relecture — enabled=${eq.enabled} niveaux=[$readBack] mB")
    }                                                                // ← FERMETURE apply

    // Gain à appliquer à la fréquence [hz], interpolé linéairement entre les
    // cinq points de [sourceHz] — en log10 de la fréquence, pas en Hz bruts :
    // l'octave 60→230 Hz doit peser autant que 3600→14000 Hz.
    // Au-delà des bornes, on prolonge par la valeur du bout plutôt que par
    // zéro : un appareil dont la dernière bande est à 16 kHz doit suivre le
    // curseur « aigus », pas retomber à plat.
    private fun interpolate(hz: Double, gains: DoubleArray): Double {
        if (hz <= sourceHz.first()) return gains.first()
        if (hz >= sourceHz.last())  return gains.last()

        val x = log10(hz)
        for (k in 0 until sourceHz.size - 1) {
            val x0 = log10(sourceHz[k])
            val x1 = log10(sourceHz[k + 1])
            if (x in x0..x1) {
                val t = (x - x0) / (x1 - x0)
                return gains[k] + t * (gains[k + 1] - gains[k])
            }
        }
        return 0.0  // inatteignable : les bornes sont traitées plus haut
    }

    // Dump unique du profil d'égaliseur de l'appareil, et de la liste des
    // effets audio que le système expose.
    //
    // À quoi ça sert : quand un même réglage ne sonne pas pareil sur deux
    // téléphones, la cause est presque toujours ici. Un appareil peut exposer
    // un autre nombre de bandes, d'autres fréquences centrales, une autre
    // plage de gains — ou faire passer la sortie par des effets maison
    // (SoundAlive, Dolby…) dont l'attachement d'un Equalizer applicatif change
    // le comportement. Comparer ce bloc entre deux appareils répond à la
    // question en une lecture.
    private fun logDeviceProfile(audioSessionId: Int) {              // ← OUVERTURE logDeviceProfile
        val eq = equalizer ?: return
        val tag = "RadioEqualizer"

        android.util.Log.d(tag, "── profil appareil ──────────────────────")
        android.util.Log.d(tag, "audioSessionId = $audioSessionId")
        android.util.Log.d(tag, "enabled        = ${eq.enabled}")
        android.util.Log.d(tag, "numberOfBands  = ${eq.numberOfBands}")
        android.util.Log.d(tag,
            "bandLevelRange = [${eq.bandLevelRange[0]}, ${eq.bandLevelRange[1]}] mB")

        for (i in 0 until eq.numberOfBands) {
            val hz = eq.getCenterFreq(i.toShort()) / 1000
            val range = eq.getBandFreqRange(i.toShort())
            android.util.Log.d(tag,
                "band $i — centre ${hz} Hz — bande [${range[0] / 1000}, ${range[1] / 1000}] Hz" +
                        " — niveau ${eq.getBandLevel(i.toShort())} mB")
        }

        // Presets du constructeur — leur simple existence indique une
        // implémentation maison plutôt que l'égaliseur générique d'Android.
        runCatching {
            val presets = (0 until eq.numberOfPresets).joinToString(", ") { p ->
                eq.getPresetName(p.toShort())
            }
            android.util.Log.d(tag, "presets        = [$presets]")
        }

        // Effets audio disponibles sur l'appareil. Sur un téléphone de marque,
        // on y voit les effets du constructeur ; sur un émulateur, presque rien.
        runCatching {
            AudioEffect.queryEffects()?.forEach { d ->
                android.util.Log.d(tag,
                    "effet disponible — ${d.name} (par ${d.implementor}, mode ${d.connectMode})")
            }
        }.onFailure {
            android.util.Log.w(tag, "queryEffects indisponible — ${it.message}")
        }
        android.util.Log.d(tag, "─────────────────────────────────────────")
    }                                                                // ← FERMETURE logDeviceProfile

    // Remet toutes les bandes à 0 dB (plat)
    fun reset() {                                                    // ← OUVERTURE reset
        val eq = equalizer ?: return
        android.util.Log.d("RadioEqualizer", "reset — all bands to 0")
        for (i in 0 until eq.numberOfBands) {
            eq.setBandLevel(i.toShort(), 0)
        }
    }                                                                // ← FERMETURE reset

    // Libère les ressources — obligatoire pour éviter les fuites audio
    fun release() {                                                  // ← OUVERTURE release
        android.util.Log.d("RadioEqualizer", "release")
        equalizer?.release()
        equalizer = null
    }                                                                // ← FERMETURE release

}                                                                    // ← FERMETURE CLASSE