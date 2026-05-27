package com.dev.gcimia.radio_service

import android.util.Log
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Metadata
import androidx.media3.extractor.metadata.icy.IcyHeaders
import androidx.media3.extractor.metadata.icy.IcyInfo
import androidx.media3.extractor.metadata.id3.ApicFrame
import androidx.media3.extractor.metadata.id3.TextInformationFrame
import androidx.media3.extractor.metadata.vorbis.VorbisComment

// Reçoit les métadonnées brutes d'ExoPlayer et les transmet à Flutter
// sans aucune interprétation. Le parsing est entièrement côté Dart.
class MetadataExtractor(private val eventStream: PlayerEventStream) {

    // ── Type de source ────────────────────────────────────────────────────────
    //
    // Pour les flux progressifs (MP3/AAC/OGG/Opus) :
    //   - Les métadonnées ICY inline sont la source fiable (onMetadata → IcyInfo)
    //   - onMediaMetadataChanged est TOUJOURS ignoré car ExoPlayer y remonte
    //     les tags ID3 du fichier encodé original, pas le titre diffusé
    //
    // Pour les flux HLS/DASH :
    //   - Pas d'ICY — onMediaMetadataChanged est la seule source de métadonnées
    //   - onMediaMetadataChanged est donc accepté
    //
    // isProgressiveSource est positionné par reset(isHls) à chaque setUrl,
    // avant que le premier événement de métadonnées arrive.
    // C'est plus fiable qu'un délai arbitraire.

    private var isProgressiveSource = true  // true par défaut — le cas le plus fréquent
    private var isIcyStream         = false // true dès qu'une ICY est reçue

    // Réinitialise l'état — à appeler à chaque changement de flux (setUrl).
    // [isHls] : true si l'URL se termine par .m3u8 ou est détectée comme HLS.
    fun reset(isHls: Boolean = false) {
        Log.d("MetadataExtractor", "reset: isHls=$isHls → isProgressiveSource=${!isHls}")
        isProgressiveSource = !isHls
        isIcyStream         = false
    }

    // Affine la détection du type de source après que les pistes sont connues.
    // Appelé depuis onTracksChanged avec le containerMimeType réel de la piste.
    // Permet de corriger la détection initiale par URL pour les flux /stream.
    fun refineSourceType(isProgressive: Boolean) {
        // On n'affine que si la détection initiale était incertaine (non-HLS).
        // Un flux déjà identifié comme HLS via .m3u8 ne peut pas devenir progressif.
        if (!isProgressiveSource) return  // HLS confirmé par l'URL → on garde
        isProgressiveSource = isProgressive
    }

    // En-têtes ICY reçus lors de la connexion initiale
    fun onIcyHeaders(headers: IcyHeaders) {
        isIcyStream = true
        val data = mutableMapOf<String, Any>()
        headers.name?.let  { data["stationName"]  = it }
        headers.genre?.let { data["stationGenre"] = it }
        headers.url?.let   { data["stationUrl"]   = it }
        if (data.isNotEmpty()) {
            eventStream.sendRawMetadata("icy_header", data)
        }
    }

    // Métadonnées arrivant pendant la lecture
    fun onMetadata(metadata: Metadata) {
        Log.d("MetadataExtractor", "onMetadata: ${metadata.length()} entries, isProgressive=$isProgressiveSource")
        for (i in 0 until metadata.length()) {
            when (val entry = metadata[i]) {

                is IcyInfo -> {
                    isIcyStream = true
                    entry.title?.let {
                        eventStream.sendRawMetadata("icy_info", mapOf("rawTitle" to it))
                    }
                }

                is TextInformationFrame -> {
                    // "continue" passe à l'entrée suivante — "return" sortirait de onMetadata
                    val value = entry.values.firstOrNull() ?: continue
                    eventStream.sendRawMetadata(
                        "id3_text",
                        mapOf("frameId" to entry.id, "value" to value)
                    )
                }

                is ApicFrame -> {
                    // Limite à 512 Ko pour ne pas saturer le canal Flutter
                    if (entry.pictureData.size <= 512 * 1024) {
                        eventStream.sendRawMetadata(
                            "id3_artwork",
                            mapOf("data" to entry.pictureData.toList())
                        )
                    }
                }

                is VorbisComment -> {
                    eventStream.sendRawMetadata(
                        "vorbis",
                        mapOf("key" to entry.key.uppercase(), "value" to entry.value)
                    )
                }
            }
        }
    }

    // Métadonnées haut niveau ExoPlayer.
    //
    // Acceptées UNIQUEMENT pour les flux HLS/DASH (isProgressiveSource = false)
    // car c'est la seule source de métadonnées disponible pour ces flux.
    //
    // Pour les flux progressifs (MP3/AAC/OGG) : toujours ignorées.
    // ExoPlayer y agrège les tags ID3 du fichier encodé original — ces tags
    // correspondent au morceau source, pas à ce qui est diffusé à la radio.
    // Les vraies métadonnées arrivent via onMetadata(IcyInfo).
    fun onMediaMetadata(mediaMetadata: MediaMetadata) {
        Log.d("MetadataExtractor", "onMediaMetadata: title=${mediaMetadata.title} artist=${mediaMetadata.artist} isProgressive=$isProgressiveSource isIcy=$isIcyStream")
        if (isProgressiveSource) return  // jamais pour les flux ICY/progressifs
        if (isIcyStream)         return  // sécurité : ICY détectée en cours de route

        val data = mutableMapOf<String, Any>()
        mediaMetadata.title?.toString()?.let  { data["title"]  = it }
        mediaMetadata.artist?.toString()?.let { data["artist"] = it }
        mediaMetadata.artworkData?.let        { data["data"]   = it.toList() }
        Log.d("MetadataExtractor", "onMediaMetadata → envoi: ${data.keys}")
        if (data.isNotEmpty()) {
            eventStream.sendRawMetadata("media", data)
        }
    }
}