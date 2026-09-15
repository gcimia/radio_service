import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  // Toutes les radios d'essai en une seule table, au lieu d'une constante par
  // flux : elles restent disponibles et l'analyseur ne signale plus de champ
  // mort. Pour tester une autre radio, changer [_selected] — rien d'autre.
  //
  static const Map<String, _Stream> _streams = {
    // ── Flux ICY progressifs ────────────────────────────────────────────────
    'Radio Sofaia':
        (url: 'https://radiosofaia.ice.infomaniak.ch/radiosofaia-high.aac',
         metadataUrl: null, mapping: null),
    'RTL Réunion':
        (url: 'https://rtlre.ice.infomaniak.ch/rtlre-64.aac',
         metadataUrl: null, mapping: null),
    'Antilles Média — Live':
        (url: 'https://antillesmedia.pro-fhi.net:1165/stream',
         metadataUrl: null, mapping: null),
    'Antilles Média — Kompa':
        (url: 'https://antillesmedia.pro-fhi.net/antillesmediakompa',
         metadataUrl: null, mapping: null),
    'Antilles Média — Zouk':
        (url: 'https://antillesmedia.pro-fhi.net/antillesmediazouk',
         metadataUrl: null, mapping: null),
    'Antilles Média — Latine':
        (url: 'https://antillesmedia.pro-fhi.net:1115/stream',
         metadataUrl: null, mapping: null),
    'Bel Radio Gpe':
        (url: 'https://stream.rcs.revma.com/a7qacprtpwzuv',
         metadataUrl: null, mapping: null),
    'RHT Haute Tension':
        (url: 'https://haute-tension.ice.infomaniak.ch/haute-tension-high.mp3',
         metadataUrl: null, mapping: null),
    'Espace FM':
        (url: 'https://listen.radioking.com/radio/16769/stream/63784',
         metadataUrl: null, mapping: null),
    'Zikak':
        (url: 'https://radio5.pro-fhi.net/listen-kowvdxtl-stream.mp3',
         metadataUrl: null, mapping: null),
    'Kot Karayib':
        (url: 'https://listen.radioking.com/radio/378136/stream/429373',
         metadataUrl: null, mapping: null),
    'Guadeloupe 1ère':
        (url: 'https://guadeloupe.ice.infomaniak.ch/guadeloupe-128.mp3',
         metadataUrl: null, mapping: null),
    // Variante avec point-virgule : https://radio3.pro-fhi.net:19004/;stream
    'Radio Rossignol':
        (url: 'https://radio3.pro-fhi.net:19004/stream',
         metadataUrl: null, mapping: null),
    'Cyber Streaming':
        (url: 'https://stunnel2.cyber-streaming.com:9222/1',
         metadataUrl: null, mapping: null),

    // ── Flux HLS ────────────────────────────────────────────────────────────
    // Vidéo Antilles Média TV — audio OK, pas de métadonnées musicales.
    'HLS — Antilles Média TV':
        (url: 'https://antillesmediavdo.pro-fhi.net:3663/live/amtvlive.m3u8',
         metadataUrl: null, mapping: null),
    'HLS — Antilles Média TV multi':
        (url: 'https://antillesmediavdo.pro-fhi.net:3663/multi_live/play.m3u8',
         metadataUrl: null, mapping: null),
    // Radio France — tags ID3 timed metadata (TIT2/TPE1) remontés par
    // MetadataExtractor.kt. Bonnes sources de test pour le chemin HLS.
    'HLS — France Inter':
        (url: 'https://stream.radiofrance.fr/franceinter/franceinter.m3u8',
         metadataUrl: null, mapping: null),
    'HLS — FIP':
        (url: 'https://stream.radiofrance.fr/fip/fip.m3u8',
         metadataUrl: null, mapping: null),
    'HLS — FIP Reggae':
        (url: 'https://stream.radiofrance.fr/fipreggae/fipreggae.m3u8',
         metadataUrl: null, mapping: null),
    'HLS — France Musique':
        (url: 'https://stream.radiofrance.fr/francemusique/francemusique.m3u8',
         metadataUrl: null, mapping: null),
    'HLS — France Musique Opéra':
        (url: 'https://stream.radiofrance.fr/francemusiqueopera/francemusiqueopera.m3u8',
         metadataUrl: null, mapping: null),
  };

  // Mappings REST conservés ici : à recopier dans une entrée de [_streams]
  // (metadataUrl + mapping) pour tester une radio sans métadonnées ICY.
  //
  //   Radio Paradise — pochette fournie par le champ 'cover' :
  //     MetadataMapping(title: 'title', artist: 'artist',
  //                     artworkUrl: 'cover', startTime: 'start_time')
  //
  //   Métis FM — JSON imbriqué sous la clé '8' :
  //     MetadataMapping(title:      '8.current_song.title',
  //                     artist:     '8.current_song.artist',
  //                     artworkUrl: '8.current_song.img')

  // ── Sélection active ───────────────────────────────────────────────────────
  // Une seule ligne à changer pour tester une autre radio.
  static const _selected = 'Antilles Média — Live';

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
  // Logo de station (mémorisé par le plugin ; le fallback dans la notification
  // n'est pas encore implémenté) :
  //   await _service.setUrl(
  //     _streams['Guadeloupe 1ère']!.url,
  //     stationName:    'Guadeloupe 1ère',
  //     stationLogoUrl: 'https://mon-serveur.com/logos/guadeloupe1ere.png',
  //   );
  //
  // Radio sans ICY, métadonnées par polling REST — Métis FM, JSON imbriqué :
  //   await _service.setUrl(
  //     'https://str0.creacast.com/metisfm.mp3',
  //     stationName:     'Métis FM',
  //     metadataUrl:     'https://metis.fm/flux/metisfm/refresh.json?ck=0',
  //     metadataMapping: const MetadataMapping(
  //       title:      '8.current_song.title',
  //       artist:     '8.current_song.artist',
  //       artworkUrl: '8.current_song.img',
  //     ),
  //   );
  //
  // Radio Paradise — pochette fournie directement par le champ 'cover' :
  //   metadataMapping: const MetadataMapping(
  //     title: 'title', artist: 'artist',
  //     artworkUrl: 'cover', startTime: 'start_time',
  //   )
  //
  // Chemin HLS : mettre _selected sur une entrée 'HLS — …'. Les métadonnées y
  // viennent des tags ID3 in-band, pas d'IcyStreamReader.

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
    // Android 13+ — demande la permission d'afficher les notifications.
    // Sans ça, la notification media et l'écran de verrouillage n'apparaissent pas.
    _requestNotificationPermission();
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

  // ── Permission notifications (Android 13+) ──────────────────────────────

  static const _permissionChannel = MethodChannel('radio_service/permissions');

  /// Demande la permission POST_NOTIFICATIONS sur Android 13+.
  /// Sans cette permission, la notification media n'apparaît pas et
  /// l'écran de verrouillage ne montre pas les contrôles de lecture.
  Future<void> _requestNotificationPermission() async {
    try {
      await _permissionChannel.invokeMethod('requestNotificationPermission');
    } catch (_) {
      // Ignore — l'appel peut échouer si le canal n'est pas implémenté
      // ou si la permission est déjà accordée / non nécessaire (< Android 13)
    }
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