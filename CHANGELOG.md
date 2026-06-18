## 0.0.3

### Fixed
* Added the missing `network_security_config.xml` resource under
  `android/src/main/res/xml/`. The Android manifest referenced
  `@xml/network_security_config`, but the file only existed in the example app,
  which caused release builds to fail during resource linking
  (`verifyReleaseResources`: "resource xml/network_security_config not found").
  The configuration permits cleartext HTTP only to the local audio proxy
  (127.0.0.1 / localhost); all other traffic remains HTTPS-only.

## 0.0.2

### Fixes
* Playback errors now surface to the UI as `PlayerError` (previously sent as
  channel errors that were never visible) — no more infinite loader when a
  station is unavailable.
* "First byte" watchdog: if no audio data arrives within 15 s of connecting,
  the stream is declared unavailable (`PlayerError`).
* The error state is no longer overwritten by the automatic `STATE_IDLE` that
  ExoPlayer emits after an error.
* `IcyStreamReader` reports reconnection-attempt exhaustion (`onUnavailable`
  callback) instead of giving up silently.

### Audio focus (Android)
* Manual audio-focus handling (replaces Media3's `handleAudioFocus`): pause on
  interruption (call, another media app), ducking on short interruptions
  (notification, GPS), resume when focus returns.
* New `autoResumeAfterFocusLoss` parameter (default `true`): when `false`,
  playback stays paused after an interruption — manual resume required.

### Lifecycle & resources (Android)
* New native `release()` method called by `RadioService.dispose()`: stops the
  foreground service and releases the player, MediaSession and notification.
  No resource survives application shutdown.
* `configure(backgroundEnabled: false)` now stops the service if it was
  running (release per feature).
* Swiping the app away from recents (`onTaskRemoved`): playback stops and
  resources are fully released.
* `dispose()` is now idempotent (guard against double release).

### Toolchain
* Aligned with Flutter 3.44: AGP 9.0.1, Kotlin 2.3.20, Gradle 9.1.0 (example),
  `android.builtInKotlin=false` (state supported by Flutter 3.44.x).
* Environment constraint: Flutter >= 3.44.0, Dart ^3.12.0.

### Misc
* Web implementation aligned with the interface (`configure`, `release`) and
  cleaned up (redundant imports, `metadataStream` member documented as
  web-specific).

## 0.0.1

First release.

### Features
* Radio stream playback (ICY / SHOUTcast / Icecast, MP3 / AAC / OGG).
* Automatic ICY metadata parsing (title, artist, station name).
* Metadata retrieval via REST API (nested JSON paths).
* Artwork resolution (iTunes / Deezer) with LRU cache.
* 5-band equalizer with presets.
* Background playback and system-notification controls (Android).
* Silence / inactive-stream detection.

### Platforms
* Android: supported.
* iOS: planned.
