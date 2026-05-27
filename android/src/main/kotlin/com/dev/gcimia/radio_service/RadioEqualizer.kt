package com.dev.gcimia.radio_service

import android.media.audiofx.Equalizer

// Gère l'égaliseur audio natif Android.
// S'attache au flux ExoPlayer via l'audioSessionId.
//
// Les 5 bandes standard Android et leurs fréquences centrales :
//   Bande 0 —    60 Hz — sous-basses
//   Bande 1 —   230 Hz — basses
//   Bande 2 —   910 Hz — médiums
//   Bande 3 —  3600 Hz — hauts médiums
//   Bande 4 — 14000 Hz — aigus
//
// La plage matérielle est [-1500, +1500] milliBels = ±15 dB.
// On reçoit des valeurs en dB depuis Dart et on convertit en mB ici.
class RadioEqualizer(audioSessionId: Int) {                          // ← OUVERTURE CLASSE

    private var equalizer: Equalizer? = null

    init {                                                           // ← OUVERTURE init
        try {
            android.util.Log.d("RadioEqualizer",
                "init — audioSessionId = $audioSessionId")

            equalizer = Equalizer(0, audioSessionId).apply {
                enabled = true

                android.util.Log.d("RadioEqualizer",
                    "numberOfBands = $numberOfBands")

                // Log des bandes disponibles pour diagnostic
                for (i in 0 until numberOfBands) {
                    android.util.Log.d("RadioEqualizer",
                        "band $i — centerFreq = ${getCenterFreq(i.toShort()) / 1000} Hz" +
                                " — range = [${bandLevelRange[0]}, ${bandLevelRange[1]}] mB")
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("RadioEqualizer", "init failed — ${e.message}")
            equalizer = null
        }
    }                                                                // ← FERMETURE init

    // Applique les 5 bandes.
    // Les valeurs reçues sont en dB dans [-15.0, +15.0].
    // Conversion : 1 dB = 100 mB — ex: +6 dB = +600 mB.
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

        // Tableau des gains indexé par numéro de bande.
        // Si l'appareil a moins de 5 bandes (rare), les bandes manquantes
        // sont ignorées. Si l'appareil en a plus, les bandes supplémentaires
        // sont remises à 0.
        val gains = listOf(sub, bass, mid, high, treble)

        for (i in 0 until bandCount) {
            // Gain pour cette bande — 0 dB si pas de valeur disponible
            val gainDb = if (i < gains.size) gains[i] else 0.0

            // Conversion dB → milliBels (1 dB = 100 mB)
            val gainMb = (gainDb * 100).toInt()

            // Clamp dans la plage autorisée par le matériel
            val (minLevel, maxLevel) = eq.bandLevelRange
            val clamped = gainMb.coerceIn(
                minLevel.toInt(),
                maxLevel.toInt(),
            ).toShort()

            android.util.Log.d("RadioEqualizer",
                "band $i — gain=${gainDb}dB — ${gainMb}mB — clamped=${clamped}mB")

            eq.setBandLevel(i.toShort(), clamped)
        }
    }                                                                // ← FERMETURE apply

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