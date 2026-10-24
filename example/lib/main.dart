import 'package:flutter/material.dart';
import 'package:radio_service/radio_service.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: RadioTestPage());
  }
}

class RadioTestPage extends StatefulWidget {
  const RadioTestPage({super.key});

  @override
  State<RadioTestPage> createState() => _RadioTestPageState();
}

/// Une entrée de la banque de flux de test.
///   url         : flux à jouer (ICY progressif ou HLS .m3u8)
///   metadataUrl : endpoint REST optionnel, pour les radios sans ICY
///   mapping     : comment lire les champs dans la réponse JSON
typedef _Stream = ({String url, String? metadataUrl, MetadataMapping? mapping});

class _RadioTestPageState extends State<RadioTestPage> {
  final _service = RadioService(
    artworkConfig: ArtworkResolverConfig(
      enabled:           true,
      priority:          [ArtworkSourceItunes(), ArtworkSourceDeezer()],
      memoryCacheSize:   100,
      diskCacheDuration: Duration(days: 7),
    ),
  );

  // ── Banque de flux de test ────────────────────────────────────────────────
  // Un flux par type pris en charge, choisi NEUTRE à dessein : ce sont les
  // « reference streams » de Radiomast, publiés pour diagnostiquer les
  // lecteurs et explicitement libres d'usage personnel et commercial. Aucune
  // station particulière n'est imposée à qui télécharge le plugin.
  //   https://www.radiomast.io/reference-streams
  //
  // Pour tester une autre radio, changer [_selected] — rien d'autre.
  //
  //   url         : flux à jouer (ICY progressif ou HLS .m3u8)
  //   metadataUrl : endpoint REST optionnel, pour les radios sans ICY
  //   mapping     : comment lire les champs dans la réponse JSON
  static const Map<String, _Stream> _streams = {
    // ── ICY progressif — un par codec ───────────────────────────────────────
    // Ces flux portent des métadonnées ICY, donc ils passent par
    // IcyStreamReader + AudioProxyServer : c'est le chemin principal du plugin.
    'MP3 128k':
        (url: 'https://streams.radiomast.io/ref-128k-mp3-stereo',
         metadataUrl: null, mapping: null),
    'AAC-LC 128k':
        (url: 'https://streams.radiomast.io/ref-128k-aaclc-stereo',
         metadataUrl: null, mapping: null),
    'HE-AAC v1 64k':
        (url: 'https://streams.radiomast.io/ref-64k-heaacv1-stereo',
         metadataUrl: null, mapping: null),
    'Ogg Vorbis 64k':
        (url: 'https://streams.radiomast.io/ref-64k-ogg-vorbis-stereo',
         metadataUrl: null, mapping: null),
    // Opus et FLAC sont reconnus par IcyStreamType mais ne figurent pas encore
    // dans le tableau des formats pris en charge du README — à éprouver.
    'Ogg Opus 64k':
        (url: 'https://streams.radiomast.io/ref-64k-ogg-opus-stereo',
         metadataUrl: null, mapping: null),
    'Ogg FLAC sans perte':
        (url: 'https://streams.radiomast.io/ref-lossless-ogg-flac-stereo',
         metadataUrl: null, mapping: null),

    // ── Cas limites utiles ──────────────────────────────────────────────────
    // Preroll : le flux commence par une annonce. Bon test du watchdog
    // « premier octet » et de l'enchaînement vers le contenu.
    'MP3 128k + preroll':
        (url: 'https://streams.radiomast.io/ref-128k-mp3-stereo-preroll',
         metadataUrl: null, mapping: null),
    // Très bas débit mono — remplissage de tampon lent, utile pour observer
    // les états de mise en tampon et la détection de silence.
    'MP3 32k mono':
        (url: 'https://streams.radiomast.io/ref-32k-mp3-mono',
         metadataUrl: null, mapping: null),

    // ── Résolution de playlist ──────────────────────────────────────────────
    // .m3u : PlaylistResolver doit extraire une URL de flux du fichier avant
    // de passer la main. Celui-ci liste tous les flux de référence — le
    // résolveur doit en retenir un. Le mécanisme .pls est identique ; toute
    // station Icecast en publie un si vous voulez l'éprouver aussi.
    'Playlist .m3u':
        (url: 'https://www.radiomast.io/reference-streams.m3u',
         metadataUrl: null, mapping: null),

    // ── HLS ─────────────────────────────────────────────────────────────────
    // Chemin différent : ExoPlayer joue l'URL directement via HlsMediaSource,
    // sans proxy ni IcyStreamReader. Les métadonnées viennent des tags ID3
    // in-band des segments, remontés par MetadataExtractor.kt.
    'HLS — MP3 128k':
        (url: 'https://streams.radiomast.io/ref-128k-mp3-stereo/hls.m3u8',
         metadataUrl: null, mapping: null),
    'HLS — HE-AAC v1 64k':
        (url: 'https://streams.radiomast.io/ref-64k-heaacv1-stereo/hls.m3u8',
         metadataUrl: null, mapping: null),
    // Station réelle, tags ID3 réels (TIT2/TPE1) : les flux de référence
    // valident le transport, celui-ci valide l'affichage titre + artiste et
    // la résolution de pochette sur le chemin HLS.
    'HLS — FIP (station réelle)':
        (url: 'https://stream.radiofrance.fr/fip/fip.m3u8',
         metadataUrl: null, mapping: null),
  };

  // ── Sélection active ───────────────────────────────────────────────────────
  // Une seule ligne à changer pour tester un autre flux.
  static const _selected = 'MP3 128k';

  Future<void> _play() async {
    final stream = _streams[_selected]!;
    await _service.setUrl(
      stream.url,
      stationName:     _selected,
      metadataUrl:     stream.metadataUrl,
      metadataMapping: stream.mapping,
    );
    await _service.player.play();
  }

  // ── Variantes — remplacer le corps de _play() ci-dessus ───────────────────
  //
  // Les flux de référence valident le transport et les codecs. Pour éprouver
  // les métadonnées musicales, la pochette et le polling REST, il faut une
  // vraie station : mettez la vôtre ci-dessous.
  //
  // Logo de station (mémorisé par le plugin ; le fallback dans la notification
  // n'est pas encore implémenté) :
  //   await _service.setUrl(
  //     'https://exemple.com/stream.mp3',
  //     stationName:    'Ma Radio',
  //     stationLogoUrl: 'https://exemple.com/logos/ma-radio.png',
  //   );
  //
  // Radio sans métadonnées ICY — titre et artiste par polling REST.
  // Le mapping décrit où lire les champs dans le JSON, en chemins pointés :
  //   await _service.setUrl(
  //     'https://exemple.com/stream.mp3',
  //     stationName:     'Ma Radio',
  //     metadataUrl:     'https://exemple.com/api/nowplaying.json',
  //     metadataMapping: const MetadataMapping(
  //       title:      'title',
  //       artist:     'artist',
  //       artworkUrl: 'artworkUrl',
  //     ),
  //   );
  //
  // JSON imbriqué — le mapping suit la hiérarchie :
  //   metadataMapping: const MetadataMapping(
  //     title:      'data.current_song.title',
  //     artist:     'data.current_song.artist',
  //     artworkUrl: 'data.current_song.img',
  //     startTime:  'data.current_song.start_time',
  //   )

  // ── État ──────────────────────────────────────────────────────────────────

  PlayerState     _state          = PlayerIdle();
  PlayerMetadata  _metadata       = const PlayerMetadata();
  PlayerPosition  _position       = LivePosition();
  EqualizerConfig _equalizerConfig = const EqualizerConfig.flat();

  bool    _isDragging = false;
  double  _dragValue  = 0.0;

  @override
  void initState() {
    super.initState();
    // Aucune permission à demander : la notification du lecteur passe par une
    // MediaSession, et Android exempte ces notifications de POST_NOTIFICATIONS.
    _service.stateStream.listen((s) => setState(() => _state = s));
    _service.metadataStream.listen((m) {
      // Stream silencieux — le flux est connecté mais la radio ne diffuse rien.
      // Affiché après 45s sans StreamTitle ICY alors que le proxy reçoit des bytes.
      if (m.isSilent) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            '${m.stationName ?? "La radio"} ne diffuse pas en ce moment',
          ),
          duration: const Duration(seconds: 6),
          backgroundColor: Colors.orange.shade700,
        ));
        return;
      }
      setState(() {
        // Clé de déduplication : artiste + titre.
        // RadioService émet deux fois pour un même titre :
        //   - émission 1 : titre+artiste immédiatement, sans pochette
        //   - émission 2 : même titre+artiste, avec pochette résolue
        // On utilise la clé artiste|titre pour distinguer un vrai changement
        // de titre (→ efface la pochette) d'un enrichissement de la même entrée
        // (→ met à jour la pochette sans remettre l'affichage à zéro).
        final newKey = '${m.artist ?? ""}|${m.title ?? ""}';
        final oldKey = '${_metadata.artist ?? ""}|${_metadata.title ?? ""}';

        if (newKey != oldKey) {
          // Nouveau titre — efface la pochette en attendant la résolution
          _metadata = m.copyWith(artworkUrl: null, artworkData: null);
        } else {
          // Même titre — enrichissement avec pochette ou mise à jour partielle
          _metadata = m;
        }
      });
    });
    _service.positionStream.listen((p) => setState(() {
      if (!_isDragging) _position = p;
    }));
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String get _stateLabel => switch (_state) {
    PlayerIdle()                => 'Arrêté',
    PlayerBuffering()           => 'Chargement…',
    PlayerPlaying()             => 'Lecture en cours',
    PlayerPaused()              => 'En pause',
    PlayerStopped()             => 'Arrêté',
    PlayerInterrupted()         => 'Reconnexion…',
    PlayerError(:final message) => 'Erreur : $message',
  };

  bool get _isPlaying => _state is PlayerPlaying;

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('radio_service — test')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            _buildArtwork(),
            const SizedBox(height: 16),
            _buildStationInfo(),
            const SizedBox(height: 8),
            _buildTrackInfo(),
            const SizedBox(height: 24),
            // _buildTimeShift(),
            const SizedBox(height: 24),
            _buildControls(),
            const SizedBox(height: 32),
            _buildEqualizer(),
          ],
        ),
      ),
    );
  }

  // ── Widgets ───────────────────────────────────────────────────────────────

  Widget _buildArtwork() {
    if (_metadata.artworkUrl != null) {
      return Image.network(
        _metadata.artworkUrl!,
        width: 180, height: 180, fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const Icon(Icons.radio, size: 80),
      );
    }
    if (_metadata.artworkData != null) {
      return Image.memory(
        _metadata.artworkData!,
        width: 180, height: 180, fit: BoxFit.cover,
      );
    }
    return const SizedBox(
      width: 180, height: 180,
      child: Icon(Icons.radio, size: 80),
    );
  }

  Widget _buildStationInfo() => Column(children: [
    Text(
      _metadata.stationName ?? 'Radio',
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
    ),
    if (_metadata.stationGenre != null)
      Text(_metadata.stationGenre!,
          style: const TextStyle(color: Colors.grey, fontSize: 13)),
  ]);

  Widget _buildTrackInfo() => Column(children: [
    // Titre : morceau en cours, ou nom de la station si pas de méta musicale
    Text(
      _metadata.title ?? _metadata.stationName ?? '',
      style: const TextStyle(fontSize: 15),
    ),
    // Artiste : vide si pas de méta musicale
    if (_metadata.artist != null)
      Text(_metadata.artist!, style: const TextStyle(color: Colors.grey)),
    const SizedBox(height: 4),
    Text('État : $_stateLabel',
        style: const TextStyle(fontSize: 12, color: Colors.grey)),
  ]);

  // Démonstration du time-shift — l'appel est commenté dans build() le temps
  // que la fonctionnalité soit tranchée. Conservée comme référence d'API.
  // ignore: unused_element
  Widget _buildTimeShift() {
    final pos = _position;
    if (pos is LivePosition) {
      return const Text('● LIVE',
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold));
    }
    final buffered    = pos as BufferedPosition;
    final sliderValue = _isDragging ? _dragValue : buffered.progress;
    final current     = _isDragging
        ? Duration(
        milliseconds:
        (_dragValue * buffered.bufferEnd.inMilliseconds).round())
        : buffered.current;
    final delay = buffered.delayFromLive;

    return Column(children: [
      Text(
        delay.inSeconds > 5
            ? '${_format(delay)} de retard sur le live'
            : '● LIVE',
        style: TextStyle(
          color:      delay.inSeconds > 5 ? Colors.orange : Colors.red,
          fontWeight: FontWeight.bold,
          fontSize:   12,
        ),
      ),
      const SizedBox(height: 4),
      Row(children: [
        Text(_format(buffered.bufferStart),
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Expanded(
          child: Slider(
            value: sliderValue.clamp(0.0, 1.0),
            onChangeStart: (v) => setState(() {
              _isDragging = true;
              _dragValue  = v;
            }),
            onChanged:    (v) => setState(() => _dragValue = v),
            onChangeEnd:  (v) {
              final ms = (v * buffered.bufferEnd.inMilliseconds).round();
              _service.player.seek(Duration(milliseconds: ms));
              setState(() => _isDragging = false);
            },
          ),
        ),
        Text(_format(buffered.bufferEnd),
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: () => _service.player
                .seek(current - const Duration(seconds: 30)),
            icon:  const Icon(Icons.replay_30, size: 20),
            label: const Text('-30s'),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: () => _service.player.seekToLive(),
            icon:  const Icon(Icons.wifi_tethering, size: 20),
            label: const Text('Live'),
          ),
        ],
      ),
    ]);
  }

  Widget _buildControls() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      ElevatedButton(
        onPressed: _play,
        child: const Text('Play'),
      ),
      ElevatedButton(
        onPressed: _isPlaying ? _service.player.pause : _service.player.play,
        child: Text(_isPlaying ? 'Pause' : 'Reprendre'),
      ),
      ElevatedButton(
        onPressed: _service.player.stop,
        child: const Text('Stop'),
      ),
    ],
  );

  Widget _buildEqualizer() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('Égaliseur',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
      ),
      _eqSlider('Sub',     '60 Hz',   _equalizerConfig.sub,
              (v) => EqualizerConfig(sub: v,    bass: _equalizerConfig.bass,
              mid: _equalizerConfig.mid,    high: _equalizerConfig.high,
              treble: _equalizerConfig.treble)),
      _eqSlider('Basses',  '230 Hz',  _equalizerConfig.bass,
              (v) => EqualizerConfig(sub: _equalizerConfig.sub, bass: v,
              mid: _equalizerConfig.mid,    high: _equalizerConfig.high,
              treble: _equalizerConfig.treble)),
      _eqSlider('Médiums', '910 Hz',  _equalizerConfig.mid,
              (v) => EqualizerConfig(sub: _equalizerConfig.sub,
              bass: _equalizerConfig.bass,  mid: v,
              high: _equalizerConfig.high,  treble: _equalizerConfig.treble)),
      _eqSlider('Hauts',   '3600 Hz', _equalizerConfig.high,
              (v) => EqualizerConfig(sub: _equalizerConfig.sub,
              bass: _equalizerConfig.bass,  mid: _equalizerConfig.mid,
              high: v,                      treble: _equalizerConfig.treble)),
      _eqSlider('Aigus',   '14 kHz',  _equalizerConfig.treble,
              (v) => EqualizerConfig(sub: _equalizerConfig.sub,
              bass: _equalizerConfig.bass,  mid: _equalizerConfig.mid,
              high: _equalizerConfig.high,  treble: v)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          _presetButton('Plat',      const EqualizerConfig.flat()),
          _presetButton('Basses+',   const EqualizerConfig.bassBoost()),
          _presetButton('Voix',      const EqualizerConfig.vocal()),
          _presetButton('Téléphone', const EqualizerConfig.phone()),
          _presetButton('Aigus+',    const EqualizerConfig.trebleBoost()),
          _presetButton('V-Shape',   const EqualizerConfig.vShape()),
        ],
      ),
    ],
  );

  Widget _eqSlider(
      String label,
      String freq,
      double value,
      EqualizerConfig Function(double) onChanged,
      ) =>
      Row(children: [
        SizedBox(
          width: 56,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 12)),
              Text(freq,  style: const TextStyle(fontSize: 10,
                  color: Colors.grey)),
            ],
          ),
        ),
        Expanded(
          child: Slider(
            min: -15, max: 15, divisions: 30,
            value: value,
            label: '${value.toStringAsFixed(1)} dB',
            onChanged: (v) => _applyEqualizer(onChanged(v)),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            value.toStringAsFixed(1),
            style: const TextStyle(fontSize: 11),
            textAlign: TextAlign.right,
          ),
        ),
      ]);

  Widget _presetButton(String label, EqualizerConfig config) =>
      OutlinedButton(
        onPressed: () => _applyEqualizer(config),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );

  void _applyEqualizer(EqualizerConfig config) {
    setState(() => _equalizerConfig = config);
    _service.equalizer.apply(config);
  }
}