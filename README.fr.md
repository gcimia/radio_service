# radio_service

Plugin Flutter pour la diffusion de webradios avec support complet des métadonnées, résolution des pochettes, égaliseur et lecture en arrière-plan.

Développé pour Android (iOS prévu). Gère les flux ICY, SHOUTcast, AAC, MP3 et les APIs REST de métadonnées.

---

## Fonctionnalités

- 📻 **Flux ICY** — MP3, AAC, OGG avec métadonnées inline (SHOUTcast / Icecast)
- 🎵 **Parsing automatique des métadonnées** — artiste, titre, nom de station depuis les headers ICY et StreamTitle
- 🖼️ **Résolution des pochettes** — recherche iTunes et Deezer avec correspondance approximative et cache LRU
- 🌐 **Polling REST** — supporte les chemins JSON imbriqués (ex: `8.current_song.title`)
- 🎚️ **Égaliseur 5 bandes** — avec préréglages (Basses+, Voix, V-Shape…)
- 🔔 **Lecture en arrière-plan + notification système** — avec contrôles média
- 🔌 **Résolution de playlists** — `.pls`, `.m3u`, RadioKing, RadioEndirect
- ⚙️ **Configurable** — activer uniquement les fonctionnalités dont vous avez besoin

---

## Installation

```yaml
dependencies:
  radio_service: ^0.1.4
```

---

## Configuration Android

### 1. Configuration de sécurité réseau

Créer `android/app/src/main/res/xml/network_security_config.xml` :

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <!-- HTTPS uniquement pour tout le trafic externe -->
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
    <!-- HTTP autorisé uniquement pour le proxy local (127.0.0.1) -->
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
        <domain includeSubdomains="false">localhost</domain>
    </domain-config>
</network-security-config>
```

### 2. AndroidManifest.xml

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />

<application
    android:networkSecurityConfig="@xml/network_security_config"
    ...>
```

---

## Démarrage rapide

```dart
import 'package:radio_service/radio_service.dart';

// Créer le service
final service = RadioService();

// Lancer un flux ICY simple
await service.setUrl('https://stream.example.com/radio.mp3');
await service.player.play();

// Écouter les métadonnées
service.metadataStream.listen((metadata) {
  print('${metadata.artist} — ${metadata.title}');
  print('Pochette : ${metadata.artworkUrl}');
});

// Écouter l'état du lecteur
service.stateStream.listen((state) {
  if (state is PlayerPlaying) print('Lecture en cours');
  if (state is PlayerError)   print('Erreur : ${state.message}');
});

// Libérer les ressources
service.dispose();
```

---

## Configuration des fonctionnalités

Toutes les fonctionnalités sont optionnelles et se configurent dans le constructeur :

```dart
RadioService(
  // Résolution des pochettes via iTunes & Deezer (désactivé par défaut)
  artworkConfig: ArtworkResolverConfig(
    enabled:           true,
    priority:          [ArtworkSourceItunes(), ArtworkSourceDeezer()],
    memoryCacheSize:   100,
    diskCacheDuration: Duration(days: 7),
  ),

  // Égaliseur 5 bandes — false libère la ressource DSP Android
  equalizerEnabled: true,   // défaut: true

  // Lecture en arrière-plan + notification système
  backgroundEnabled: true,  // défaut: true

  // Reprise automatique de la lecture après une interruption audio
  // (appel téléphonique, autre appli média). false = reprise manuelle.
  autoResumeAfterFocusLoss: true,  // défaut: true
)
```

### Configuration minimale (audio uniquement)

```dart
RadioService(
  equalizerEnabled:  false,
  backgroundEnabled: false,
)
```

---

## Métadonnées REST

Pour les stations qui n'exposent pas les métadonnées dans le flux ICY,
vous pouvez interroger un endpoint REST :

```dart
// JSON plat : { "title": "...", "artist": "..." }
await service.setUrl(
  'https://stream.example.com/radio.mp3',
  metadataUrl: 'https://api.example.com/nowplaying',
);

// JSON imbriqué avec mapping personnalisé
// ex: { "8": { "current_song": { "title": "...", "artist": "..." } } }
await service.setUrl(
  'https://stream.example.com/radio.mp3',
  metadataUrl: 'https://api.example.com/nowplaying.json?ck=0',
  metadataMapping: MetadataMapping(
    title:      '8.current_song.title',
    artist:     '8.current_song.artist',
    artworkUrl: '8.current_song.img',
  ),
);
```

Les URLs de pochettes relatives (ex: `/uploads/cover.jpg`) sont automatiquement
résolues en URLs absolues en utilisant le domaine de l'endpoint de métadonnées.

---

## Égaliseur

```dart
// Appliquer un préréglage
service.equalizer.apply(const EqualizerConfig.bassBoost());

// Réglage personnalisé (dB, plage : -15 à +15)
service.equalizer.apply(EqualizerConfig(
  sub:    3.0,
  bass:   2.0,
  mid:    0.0,
  high:  -1.0,
  treble: 1.0,
));

// Préréglages disponibles
EqualizerConfig.flat()         // Plat
EqualizerConfig.bassBoost()    // Basses+
EqualizerConfig.vocal()        // Voix
EqualizerConfig.phone()        // Téléphone
EqualizerConfig.trebleBoost()  // Aigus+
EqualizerConfig.vShape()       // V-Shape
```

---

## Contrôles du lecteur

```dart
service.player.play();
service.player.pause();
service.player.stop();
service.player.setVolume(0.8);  // 0.0 à 1.0

// Décalage temporel (quand le buffer est disponible)
service.player.seek(position);
service.player.seekToLive();
```

---

## Focus audio (Android)

Le plugin gère automatiquement le focus audio :

- **Appel téléphonique / autre appli média** → la lecture se met en pause,
  puis reprend à la fin de l'interruption (si `autoResumeAfterFocusLoss`
  est `true`).
- **Interruption courte** (son de notification, guidage GPS) → le volume est
  baissé (ducking), puis restauré.
- Avec `autoResumeAfterFocusLoss: false`, la lecture reste en pause après une
  interruption et l'utilisateur reprend manuellement.

---

## États et métadonnées

### PlayerState

```dart
service.stateStream.listen((state) {
  switch (state) {
    case PlayerIdle():       // Aucun flux chargé
    case PlayerBuffering():  // Connexion / mise en tampon
    case PlayerPlaying():    // Lecture en cours
    case PlayerPaused():     // En pause
    case PlayerStopped():    // Arrêté
    case PlayerError(:final message): // Erreur
  }
});
```

`PlayerError` est émis quand le flux est indisponible : connexion refusée,
erreur HTTP, échec DNS, erreur de lecture — ou quand aucune donnée audio
n'arrive dans les 15 secondes suivant la connexion (garde-fou station
injoignable). L'UI doit gérer cet état pour arrêter le loader et informer
l'utilisateur.

### PlayerMetadata

```dart
service.metadataStream.listen((m) {
  m.title        // Titre du morceau en cours
  m.artist       // Artiste
  m.artworkUrl   // URL de la pochette (iTunes/Deezer ou REST)
  m.artworkData  // Pochette en bytes (si téléchargée)
  m.stationName  // Nom de la station (headers ICY)
  m.stationGenre // Genre de la station
});
```

---

## Formats supportés

| Format | Métadonnées ICY | Notes |
|--------|----------------|-------|
| MP3    | ✅ | SHOUTcast / Icecast |
| AAC    | ✅ | `.aac`, `.aacp` |
| OGG    | ✅ | Vorbis |
| HLS    | ➖ | Supporté via `isHls: true` (pas de métadonnées ICY inline ; utiliser le polling REST) |

### Playlists

| Format | Support |
|--------|---------|
| `.pls` | ✅ |
| `.m3u` | ✅ |
| RadioKing (`listen.radioking.com`) | ✅ |
| RadioEndirect (`radioendirect.net`) | ✅ |

---

## Cycle de vie

Appelez `dispose()` quand le lecteur n'est plus nécessaire (par exemple quand
l'utilisateur quitte l'application). Cela arrête le flux, stoppe le foreground
service Android et libère le player, la media session et la notification :

```dart
await service.dispose();
```

Balayer l'application depuis l'écran des applis récentes arrête également la
lecture et libère toutes les ressources natives.

---

## iOS

Le support iOS est prévu. Les contributions sont les bienvenues.

---

## Licence

MIT
