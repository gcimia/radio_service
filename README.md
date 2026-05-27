# radio_service

A Flutter plugin for streaming internet radio with full metadata support, artwork resolution, equalizer, and background playback.

Built for Android (iOS support planned). Handles ICY streams, SHOUTcast, AAC, MP3, and REST metadata APIs.

---

## Features

- 📻 **ICY stream support** — MP3, AAC, OGG with inline metadata (SHOUTcast / Icecast)
- 🎵 **Automatic metadata parsing** — artist, title, station name from ICY headers and StreamTitle
- 🖼️ **Artwork resolution** — iTunes and Deezer lookups with fuzzy matching and LRU cache
- 🌐 **REST metadata polling** — supports nested JSON paths (e.g. `8.current_song.title`)
- 🎚️ **5-band equalizer** — with presets (Bass Boost, Vocal, V-Shape…)
- 🔔 **Background playback + system notification** — with media controls
- 🔌 **Playlist resolution** — `.pls`, `.m3u`, RadioKing, RadioEndirect
- ⚙️ **Configurable** — enable only the features you need

---

## Installation

```yaml
dependencies:
  radio_service: ^0.1.0
```

---

## Android Setup

### 1. Network security config

Create `android/app/src/main/res/xml/network_security_config.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <!-- HTTPS only for all external traffic -->
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
    <!-- HTTP allowed for local proxy only (127.0.0.1) -->
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

## Quick Start

```dart
import 'package:radio_service/radio_service.dart';

// Create the service
final service = RadioService();

// Play a simple ICY stream
await service.setUrl('https://stream.example.com/radio.mp3');
await service.player.play();

// Listen to metadata
service.metadataStream.listen((metadata) {
  print('${metadata.artist} — ${metadata.title}');
  print('Artwork: ${metadata.artworkUrl}');
});

// Listen to player state
service.stateStream.listen((state) {
  if (state is PlayerPlaying) print('Playing');
  if (state is PlayerError)   print('Error: ${state.message}');
});

// Dispose when done
service.dispose();
```

---

## Configuration

All features are optional and can be toggled in the constructor:

```dart
RadioService(
  // Artwork resolution via iTunes & Deezer (default: disabled)
  artworkConfig: ArtworkResolverConfig(
    enabled:           true,
    priority:          [ArtworkSourceItunes(), ArtworkSourceDeezer()],
    memoryCacheSize:   100,
    diskCacheDuration: Duration(days: 7),
  ),

  // 5-band equalizer — set false to release Android DSP resource
  equalizerEnabled: true,   // default: true

  // Background playback + system notification
  backgroundEnabled: true,  // default: true
)
```

### Minimal setup (audio only)

```dart
RadioService(
  equalizerEnabled:  false,
  backgroundEnabled: false,
)
```

---

## REST Metadata

For stations that don't expose metadata in the ICY stream, you can poll a REST endpoint:

```dart
// Simple flat JSON: { "title": "...", "artist": "..." }
await service.setUrl(
  'https://stream.example.com/radio.mp3',
  metadataUrl: 'https://api.example.com/nowplaying',
);

// Nested JSON with custom mapping
// e.g. { "8": { "current_song": { "title": "...", "artist": "..." } } }
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

Relative artwork URLs (e.g. `/uploads/cover.jpg`) are automatically resolved
to absolute URLs using the metadata endpoint's base domain.

---

## Equalizer

```dart
// Apply a preset
service.equalizer.apply(const EqualizerConfig.bassBoost());

// Custom bands (dB, range: -15 to +15)
service.equalizer.apply(EqualizerConfig(
  sub:    3.0,
  bass:   2.0,
  mid:    0.0,
  high:  -1.0,
  treble: 1.0,
));

// Available presets
EqualizerConfig.flat()
EqualizerConfig.bassBoost()
EqualizerConfig.vocal()
EqualizerConfig.phone()
EqualizerConfig.trebleBoost()
EqualizerConfig.vShape()
```

---

## Player Controls

```dart
service.player.play();
service.player.pause();
service.player.stop();
service.player.setVolume(0.8);  // 0.0 to 1.0

// Time-shift (when buffer is available)
service.player.seek(position);
service.player.seekToLive();
```

---

## Metadata & States

### PlayerState

```dart
service.stateStream.listen((state) {
  switch (state) {
    case PlayerIdle():       // No stream loaded
    case PlayerBuffering():  // Connecting / buffering
    case PlayerPlaying():    // Audio playing
    case PlayerPaused():     // Paused
    case PlayerStopped():    // Stopped
    case PlayerError(:final message): // Error
  }
});
```

### PlayerMetadata

```dart
service.metadataStream.listen((m) {
  m.title        // Current track title
  m.artist       // Current artist
  m.artworkUrl   // Artwork URL (resolved from iTunes/Deezer or REST)
  m.artworkData  // Artwork as bytes (if downloaded)
  m.stationName  // Station name (from ICY headers)
  m.stationGenre // Station genre
});
```

---

## Supported Stream Types

| Format | ICY Metadata | Notes |
|--------|-------------|-------|
| MP3    | ✅ | SHOUTcast / Icecast |
| AAC    | ✅ | `.aac`, `.aacp` |
| OGG    | ✅ | Vorbis |
| HLS    | 🔜 | Planned |

### Playlist formats

| Format | Support |
|--------|---------|
| `.pls` | ✅ |
| `.m3u` | ✅ |
| RadioKing (`listen.radioking.com`) | ✅ |
| RadioEndirect (`radioendirect.net`) | ✅ |

---

## iOS

iOS support is planned. Contributions welcome.

---

## License

MIT
