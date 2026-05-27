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

class _RadioTestPageState extends State<RadioTestPage> {
  final _service = RadioService(
    artworkConfig: ArtworkResolverConfig(
      enabled:           true,
      priority:          [ArtworkSourceItunes(), ArtworkSourceDeezer()],
      memoryCacheSize:   100,
      diskCacheDuration: Duration(days: 7),
    ),
  );

  // Radio Sofaia — flux MP3 + endpoint REST public avec artwork
  static const _streamUrl0 = "https://radiosofaia.ice.infomaniak.ch/radiosofaia-high.aac"
  ;
  static const _streamUrl01   = 'https://rtlre.ice.infomaniak.ch/rtlre-64.aac';



  // Antilles Média — flux ICY sans REST
  static const _streamUrl1 = 'https://antillesmedia.pro-fhi.net:1165/stream'; // Live
  static const _streamUrl2 = "https://antillesmedia.pro-fhi.net:1065/stream"; // Kompa
  static const _streamUrl3 = 'https://antillesmedia.pro-fhi.net:1045/stream'; // Zouk
  static const _streamUrl4 = "https://antillesmedia.pro-fhi.net:1135/stream"; // Latine

  // Bel Radio Gpe
  static const _streamUrl5 = 'https://stream.rcs.revma.com/a7qacprtpwzuv';
  // RHT
  static const _streamUrl6 = "https://haute-tension.ice.infomaniak.ch/haute-tension-high.mp3";
  // ESPACE FM
  static const _streamUrl7 = "https://listen.radioking.com/radio/16769/stream/63784";
  // ZIKAK
  static const _streamUrl8 = "https://radio5.pro-fhi.net/listen-kowvdxtl-stream.mp3";
  // KOTKARAYIB
  static const _streamUrl9 = "https://listen.radioking.com/radio/378136/stream/429373";
  // GUADELOUPE 1ERE
  static const _streamUrl10 = "https://guadeloupe.ice.infomaniak.ch/guadeloupe-128.mp3";

  // ── Flux HLS pour test ────────────────────────────────────────────────────
  // Flux vidéo Antilles Média TV — audio HLS (pas de métadonnées musicales)
  static const _hlsAmtvLive  = 'https://antillesmediavdo.pro-fhi.net:3663/live/amtvlive.m3u8';
  static const _hlsAmtvMulti = 'https://antillesmediavdo.pro-fhi.net:3663/multi_live/play.m3u8';
  // Radio France — flux HLS officiels avec tags ID3 timed metadata
  // Ces flux contiennent titre + artiste via TextInformationFrame (TIT2/TPE1)
  static const _hlsFranceInter  = 'https://stream.radiofrance.fr/franceinter/franceinter.m3u8';
  static const _hlsFip          = 'https://stream.radiofrance.fr/fip/fip.m3u8';
  static const _hlsFipReggae    = 'https://stream.radiofrance.fr/fipreggae/fipreggae.m3u8';
  static const _hlsFranceMusique = 'https://stream.radiofrance.fr/francemusique/francemusique.m3u8';
  static const _hlsMusiqueOpera = "https://stream.radiofrance.fr/francemusiqueopera/francemusiqueopera.m3u8";


  // Mapping Radio Paradise — fournit une pochette via 'cover'
  static const _mappingRP = MetadataMapping(
    title:      'title',
    artist:     'artist',
    artworkUrl: 'cover',
    startTime:  'start_time',
  );

  // Mapping Métis FM — JSON imbriqué sous la clé '8'
  static const _mappingMetis = MetadataMapping(
    title:      '8.current_song.title',
    artist:     '8.current_song.artist',
    artworkUrl: '8.current_song.img',
  );

  // ── Sélection active ───────────────────────────────────────────────────────
  // Changer _play() pour tester une radio différente.
  // Radio ICY simple : setUrl(url) — pas de paramètres optionnels.
  // Radio avec REST  : ajouter metadataUrl + metadataMapping.
  // stationName      : affiché dans la notification avant l'ICY (optionnel).
  Future<void> _play() => _service
      .setUrl(_streamUrl1, stationName: 'Guadeloupe 1ère')
      .then((_) => _service.player.play());

  // Exemples commentés — décommenter pour tester :
  //
  // Avec logo station (fallback si pas de pochette) :
  // Future<void> _play() => _service
  //     .setUrl(_streamUrl1,
  //   stationName:    'Antilles Média Radio',
  //   stationLogoUrl: 'https://antillesmedia.com/wp-content/uploads/2024/06/am-zouk-370x370.png',
  // ).then((_) => _service.player.play());

  // ── Test HLS — décommenter pour tester ──────────────────────────────────
  // Antilles Média TV (vidéo HLS — audio OK, pas de métas musicales) :
  // Future<void> _play() => _service
  //   .setUrl(_hlsAmtvLive, stationName: 'Antilles Média TV')
  //   .then((_) => _service.player.play());
  //
  // France Inter HLS (audio avec tags ID3 timed metadata — titre + artiste) :
  // Future<void> _play() => _service
  //   .setUrl(_hlsFranceInter, stationName: 'France Inter')
  //   .then((_) => _service.player.play());
  //
  // FIP Reggae HLS (audio avec tags ID3 — bonne source de test zouk/reggae) :
  // Future<void> _play() => _service
  //   .setUrl(_hlsFipReggae, stationName: 'FIP Reggae')
  //   .then((_) => _service.player.play());

  //
  // FIP Reggae HLS (audio avec tags ID3 — bonne source de test zouk/reggae) :
  // Future<void> _play() => _service
  //   .setUrl(_hlsMusiqueOpera, stationName: 'France Musique Opéra')
  //   .then((_) => _service.player.play());

  // Avec logo station (fallback si pas de pochette) :
  // Future<void> _play() => _service
  //   .setUrl('https://guadeloupe.ice.infomaniak.ch/guadeloupe-128.mp3',
  //     stationName:    'Guadeloupe 1ère',
  //     stationLogoUrl: 'https://mon-serveur.com/logos/guadeloupe1ere.png',
  //   ).then((_) => _service.player.play());
  //
  // Métis FM (REST JSON imbriqué) :
  // Future<void> _play() => _service.setUrl(
  //   'https://str0.creacast.com/metisfm.mp3',
  //   stationName:     'Métis FM',
  //   stationLogoUrl:  'https://mon-serveur.com/logos/metisfm.png',
  //   metadataUrl:     'https://metis.fm/flux/metisfm/refresh.json?ck=0',
  //   metadataMapping: _mappingMetis,
  // ).then((_) => _service.player.play());
  //
  // Sofaia AAC (ICY pur) :
  // Future<void> _play() => _service
  //   .setUrl('https://radiosofaia.ice.infomaniak.ch/radiosofaia-high.aac',
  //     stationName:    'Radio Sofaia',
  //     stationLogoUrl: 'https://mon-serveur.com/logos/sofaia.png',
  //   ).then((_) => _service.player.play());

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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            '\${m.stationName ?? "La radio"} ne diffuse pas en ce moment',
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
        errorBuilder: (_, __, ___) => const Icon(Icons.radio, size: 80),
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