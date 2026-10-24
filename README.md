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
  radio_service: ^0.1.7
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
  if (state is PlayerPlaying)     print('Playing');
  if (state is PlayerInterrupted) print('Reconnecting…');
  if (state is PlayerError)       print('Error: ${state.message}');
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

  // Resume playback automatically after an audio interruption
  // (phone call, other media app). Set false for manual resume.
  autoResumeAfterFocusLoss: true,  // default: true
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
service.player.pause();   // releases the source — see "Pause" below
service.player.stop();
service.player.setVolume(0.8);  // 0.0 to 1.0

// Time-shift (when buffer is available)
service.player.seek(position);
service.player.seekToLive();
```

---

## Pause

`pause()` stops the Dart networking layer (ICY reader + audio proxy) as well as
the native player, and `play()` reloads the station.

This is deliberate. A live stream has no "resume": keeping the connection alive
through a pause fills a buffer nobody drains, the link eventually breaks, and
resuming then plays from a dead source — no sound, no error. And even when the
source holds, resuming where you left off replays the past until the buffer
drains: ten minutes paused, ten minutes behind. **A live stream is not resumed,
it is rejoined.** The reconnection `play()` performs is the correct behaviour,
not a cost.

Consequences for the host:

- Resuming costs a reconnection (roughly a second), and metadata restart from
  the station's next ICY block.
- Nothing is consumed on the network while paused.
- HLS is unaffected: ExoPlayer owns the connection there, so pause stays a pure
  native pause.
- **Only an explicit `pause()` releases the source.** A pause caused by audio
  focus (incoming call, headphones unplugged) is triggered natively and does
  not — intentionally, so a short interruption resumes instantly. A long focus
  interruption therefore still strands the source; handle it host-side by
  calling `setUrl()` again on resume.

---

## Audio Focus (Android)

The plugin manages audio focus automatically:

- **Phone call / other media app** → playback pauses, then resumes when the
  interruption ends (if `autoResumeAfterFocusLoss` is `true`).
- **Short interruption** (notification sound, GPS guidance) → volume is
  lowered (ducking), then restored.
- With `autoResumeAfterFocusLoss: false`, playback stays paused after an
  interruption and the user resumes manually.

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
    case PlayerInterrupted():// Interrupted — the plugin is reconnecting
    case PlayerError(:final message): // Error
  }
});
```

`PlayerState` is a sealed class: adding a member is a breaking change on
purpose. An exhaustive `switch` in your app stops compiling, which is where
you want to find out — not on the user's screen.

`PlayerInterrupted` means the Dart layer can no longer feed the stream:
network outage, station momentarily unreachable, or no audio byte received
within 15 seconds of connecting. **It is not an error and not a stop.** The
plugin keeps reconnecting on its own, indefinitely, for as long as playback
has not been stopped. Show "reconnecting", keep the station selected, and do
not clear the UI. Leaving the state needs no dedicated event: `PlayerPlaying`
is emitted again as soon as audio flows.

`PlayerError` is emitted for a playback error reported by the native player.
Since 0.1.5 a network outage no longer produces it.

---

## Reconnection

The plugin owns the connection, so it owns the reconnection.

- **No retry cap.** It reconnects for as long as the listener has not stopped
  playback.
- **Bounded increasing backoff**: 1 s, 2 s, 4 s, 8 s, then 15 s repeated.
- A mid-stream drop and a clean end of stream are treated identically.
- `player.stop()` is what ends it — it stops the Dart networking layer as well
  as native playback.

Your app knows the network is back before the plugin does. If you have a
connectivity module, shorten the wait:

```dart
connectivity.onRestored.listen((_) => service.retryNow());
```

`retryNow()` shortens the current backoff and reconnects immediately. It is
strictly an optimisation — without it playback still recovers, just later.
It has no effect on HLS streams, where ExoPlayer owns the connection.

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
| HLS    | ➖ | Supported via `isHls: true` (no inline ICY metadata; use REST polling) |

The example app ships a bank of neutral reference streams — one per codec,
plus HLS, a playlist and two edge cases (preroll, very low bitrate). They come
from [Radiomast's reference streams](https://www.radiomast.io/reference-streams),
published for diagnosing players and free for personal and commercial use, so
nothing ties the example to any particular station. Point `_selected` at one of
them, or drop your own station in.

### Playlist formats

| Format | Support |
|--------|---------|
| `.pls` | ✅ |
| `.m3u` | ✅ |
| RadioKing (`listen.radioking.com`) | ✅ |
| RadioEndirect (`radioendirect.net`) | ✅ |

---

## Lifecycle

Call `dispose()` when the player is no longer needed (e.g. when the user
quits the app). It stops the stream, stops the Android foreground service and
releases the player, the media session and the notification:

```dart
await service.dispose();
```

Swiping the app away from the recent apps screen also stops playback and
releases all native resources.

---

## Platforms

| Platform | Status |
|----------|--------|
| Android  | ✅ Supported (ExoPlayer Media3, background service, lock screen, equalizer) |
| iOS      | ⛔ Not implemented — generated skeleton only |
| macOS / Windows / Linux | ⛔ Not implemented — generated skeleton only |
| Web      | ⛔ Not implemented — `RadioServiceWeb` exists but the `RadioService` facade depends on `dart:io` |

Only `android` is declared in `pubspec.yaml`. Declaring the others would
register a plugin answering no method, so every call would raise
`MissingPluginException`. `RadioService.isPlatformSupported` reports this, and
`setUrl()` emits a `PlayerError` naming the platform rather than failing deep
inside the channel.

The whole Dart layer — ICY connection, local audio proxy, metadata parsing,
playlist resolution, artwork resolution and the reconnection policy — is
already platform independent. What each port needs is the playback engine and
the system integration: notification / lock screen, audio focus, equalizer.

---

## iOS

iOS support is planned. Contributions welcome.

---

## License

MIT
