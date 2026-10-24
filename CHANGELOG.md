## 0.1.7

### BREAKING
* **`pause()` now releases the source.** It stops the Dart networking layer
  (ICY reader + audio proxy) as well as the native player, and `play()` reloads
  the station. Call sites are unchanged — `service.player.pause()` has the same
  signature — but the behaviour is not: resuming costs a reconnection of about
  a second, and metadata restart from the station's next ICY block. Hosts that
  relied on an instantaneous resume should expect a short buffering state.
  HLS is unaffected.

### Fixed — a play button that did nothing at all
* Until 0.1.6, `pause()` deliberately kept the stream alive "to allow an
  instant resume". The ICY reader therefore kept pulling the station and
  filling a local buffer **that nobody drained**. After a while the link broke;
  resuming then started playback on a dead source, which produces **no sound
  and no error either** — no state changed, no screen moved, and the listener
  concluded they had missed the button. A silent button is worse than one that
  fails: a failure is visible and gets reported, silence just gets repeated.
  `pause()` now releases the source and `play()` reloads it.
* A live stream is not resumed, it is rejoined. Even with the source intact,
  resuming where playback stopped replays the past until the buffer drains —
  ten minutes paused, ten minutes behind. Reloading is the correct behaviour,
  not a workaround.
* Pausing no longer looks like a network interruption: the release bumps the
  stream generation token, so the disconnection it causes cannot be reported as
  `PlayerInterrupted`.

### Fixed — the notification did not open the app
* `MediaSession` now carries a `setSessionActivity(...)`: the intent Media3
  hands to **every** system surface that queries the session — lock screen,
  system media controls, Android Auto, watch. Without it none of them knew
  where to go.
* The hand-built notification now carries a `setContentIntent(...)` of its own.
  `MediaStyleNotificationHelper.MediaStyle(session)` does **not** reuse the
  session activity as the content intent of a notification built by hand, so
  setting only `setSessionActivity` would have left the notification body inert.
* No host application is named: `getLaunchIntentForPackage(packageName)` yields
  the entry point of whichever app embeds the plugin, so the plugin stays
  universal. `FLAG_IMMUTABLE` is mandatory from Android 12 (API 31);
  `SINGLE_TOP | CLEAR_TOP` avoid stacking a second instance over an app that is
  already open.

### Removed — an unreachable permission handler
* The `radio_service/permissions` method channel and its
  `requestNotificationPermission` handler are gone, along with the now-unused
  `ActivityAware` implementation. Nothing in `lib/` ever called them.
* The permission was never needed: the player's notification goes through a
  `MediaSession`, and Android explicitly exempts those notifications from
  `POST_NOTIFICATIONS` — which is why it has always displayed without anything
  being granted. Dead code shaped like a feature is worse than no feature: the
  day someone relies on it, they are wrong and it takes them a while to see why.
* The `POST_NOTIFICATIONS` line **stays in the manifest**, documented. A
  declaration has no effect until something requests it, and it spares a host
  that posts its own notifications from adding it. Requesting it is the host's
  job, not the plugin's.
* The example app no longer calls the removed channel.

### Example app
* The station bank is now neutral: one reference stream per supported codec
  (MP3, AAC-LC, HE-AAC, Ogg Vorbis, Ogg Opus, Ogg FLAC), plus HLS, an `.m3u`
  playlist to exercise `PlaylistResolver`, and two edge cases — a stream with a
  preroll and a 32 kbps mono one. They come from Radiomast's reference streams,
  published for diagnosing players and free for personal and commercial use.
  Whoever downloads the plugin no longer inherits someone else's stations.
  One real station (FIP, HLS) is kept to exercise real in-band ID3 metadata and
  artwork resolution, and the REST-metadata examples became generic templates.

### Known gap — focus-driven pauses
* Only an **explicit** `pause()` releases the source. A pause caused by audio
  focus (incoming call, headphones unplugged via `handleAudioBecomingNoisy`) is
  triggered natively and bypasses `PlayerController`, so it does not release.
  That is intentional for a short interruption — instant resume is worth more
  there — but a long focus interruption still strands the source exactly as
  before. Closing it properly requires deciding what happens to automatic
  resume when the stream has to be re-prepared first; that deserves its own
  release rather than a passing change.

## 0.1.6

Housekeeping release — no behaviour change to playback, metadata or
reconnection. Cleared every analyzer warning and info, declared only the
platform that actually exists, and moved the Android build to the Kotlin DSL
with the declarative `plugins` block.

### BREAKING (packaging and environment, not API)
* Minimum environment raised to **Flutter 3.47 / Dart ^3.13**, from
  Flutter 3.44 / Dart ^3.12. Built-in Kotlin under AGP 9 needs Flutter 3.47,
  and staying below it would have kept the `android.builtInKotlin=false`
  opt-out alive — an opt-out that AGP 10 removes.
* The plugin now declares **Android only** in `pubspec.yaml`. `ios`, `macos`,
  `windows`, `linux` and `web` are no longer declared: those folders hold
  nothing but the `flutter create` skeleton (`getPlatformVersion` and nothing
  else), so declaring them registered a plugin that answered no method and
  every call raised `MissingPluginException`. The sources are kept as the
  starting point for the ports — re-adding an entry is all it takes.
* `ArtworkCache.diskCacheDuration` and `ArtworkCache.diskCacheDir` are now
  public fields (they were private and only assigned). Internal class; no
  impact on host applications.

### Added
* `RadioService.isPlatformSupported` — true on Android, false elsewhere.
* On an unsupported platform, `setUrl()` now emits a `PlayerError` naming the
  platform instead of letting a `MissingPluginException` surface from inside
  the channel.
* The constructor's fire-and-forget `configure()` call is guarded: its failure
  is logged instead of becoming an unhandled async error. Constructing
  `RadioService` on iOS or desktop previously threw out of band.

### Android build — Kotlin DSL and new AGP DSL
* `android/build.gradle` (Groovy) replaced by `android/build.gradle.kts`, and
  `android/settings.gradle` by `android/settings.gradle.kts`.
* The declarative `plugins { id("com.android.library") }` block replaces
  `apply plugin:`, and the module's own `buildscript { classpath(AGP/KGP) }`
  is gone: the plugin module is a subproject of the application's build, so
  the versions come from the app's `pluginManagement`. The old file pinned a
  second AGP version for nothing.
* `dependencies { }` moved out of `android { }`, where it only worked through
  a Groovy delegation quirk.
* `android.newDsl=false` and `android.builtInKotlin=false` removed from the
  example's `gradle.properties`. Both opt-outs disappear in AGP 10, and the
  move to Flutter 3.47 unblocks built-in Kotlin. The plugin module applies no
  Kotlin Gradle Plugin of its own — AGP provides it.
* Media3 bumped to 1.11.1.

### Cleanup — analyzer down to zero
* Removed redundant imports (`dart:typed_data` covered by
  `package:flutter/foundation.dart`, `player_state` / `player_position`
  covered by the platform interface, unused imports in the platform interface
  whose `export` lines stay).
* `MethodChannelRadioService` uses null-aware map elements (`'key': ?value`)
  instead of `if (x != null)` entries.
* `ArtworkCache` uses initializing formals.
* Braces added around single-statement `if` bodies in `MetadataPoller` and
  `RadioService`.
* Angle brackets escaped in the `IcyStreamReader` doc comments.
* Tests import through `package:radio_service/…` instead of relative `../lib/`
  paths; removed an unused stub parameter and a redundant import.
* The example app's twenty-odd loose stream constants are gathered into one
  used `_streams` table — nothing lost, one line (`_selected`) to change to
  test another station. The empty integration test became a real construct /
  dispose smoke test.

### Misc
* iOS and macOS podspecs are no longer the generated template (version,
  summary, description, homepage, author), and state plainly that the
  platform is not implemented yet.

## 0.1.5

### BREAKING
* New `PlayerInterrupted` member in the `PlayerState` sealed class. Any
  exhaustive `switch` over `PlayerState` in the host application **stops
  compiling** until the new case is handled. This is the intended behaviour:
  the failure shows up at build time instead of on the user's screen. Handle
  it as "reconnecting" — it is neither a user-requested stop nor a broken
  station.
* Hosts must move their dependency to `v0.1.5` and run `flutter pub get`
  (pub's git cache is aggressive — use `flutter pub cache repair`, or delete
  the entry under `PubCache/git/`, if the old sources stick around).

### Fixed — the "source error" lock after a network outage
* An in-flight stream teardown could cancel the stream that had replaced it.
  `_stopStream()` wrote its shared fields (`_icyReader`, `_proxy`) *after* its
  `await`s, so a teardown started during a network incident resumed once the
  next station had already started — and stopped that brand new proxy.
  ExoPlayer was then fed nothing and reported `source error` on a perfectly
  healthy station. That is the reported "the source error blocks the other
  stations". Shared fields are now detached before the first `await`.
* Two reconnection loops could run in parallel. `IcyStreamReader` re-entered
  `_connect()` through `Future.delayed` and at end of stream, guarded only by
  the shared `_running` boolean; a resumption waking up just after `start()`
  saw `true`, believed it was legitimate, and reconnected — to the *new*
  station's URL, alongside the real loop. Both wrote `_sub` and `_client`, and
  the orphan kept pushing its bytes into the proxy. The reader now runs a
  single loop guarded by a generation token that every async resumption and
  every callback compares against before acting.
* `RadioService` callbacks (`onAudioBytes`, `onMetadata`, `onConnected`,
  `onUnavailable`, first-byte watchdog) read the shared `_proxy` field instead
  of the instance they were created for, so a stale reader could push into a
  new station's proxy. They now capture the proxy instance and a stream
  generation token.
* `AudioProxyServer` had the same late-field-write pattern in `stop()`, and
  `_handleRequest()` could clear a `_currentRequest` belonging to a newer
  connection.
* Resolved artwork could install a stale track's cover as the notification
  fallback when the download outlived the track.

### Changed — reconnection policy
* **No retry cap.** The plugin reconnects for as long as the listener has not
  stopped playback. The previous policy gave up permanently after 5 attempts
  (15 to 65 seconds) — shorter than a tunnel, a lift or a cell handover, and
  nothing ever retried afterwards.
* **Bounded increasing backoff**: 1 s, 2 s, 4 s, 8 s, then 15 s repeated.
  No hammering an absent network, no one-minute wait when it returns in three
  seconds.
* `onError` (mid-stream drop) and `onDone` (clean end of stream) now get the
  same treatment. The previous asymmetry — a drop counted towards the cap, a
  clean end reset the counter to zero — was an accident, not an intent.
* `IcyStreamReader.onUnavailable` no longer means "giving up" but "this has
  been failing for a while". It is an advisory for the UI: it no longer tears
  down the reader or the proxy, and the loop keeps retrying behind it.
* The first-byte watchdog (15 s) now emits `PlayerInterrupted` instead of
  `PlayerError`, and stops nothing.
* `player.stop()` now also stops the Dart networking layer (reader + proxy)
  before the native stop. Without it, unbounded reconnection would keep
  consuming data and battery after a deliberate stop. The call site does not
  change.

### Added
* `PlayerInterrupted` state — playback is interrupted and the plugin is
  retrying. Leaving the state needs no explicit event: ExoPlayer emits
  `PlayerPlaying` again as soon as bytes flow.
* `RadioService.retryNow()` — shortens the current backoff and reconnects
  immediately. For hosts that know the network is back (a connectivity module)
  before the plugin does. Strictly optional: playback recovers on its own
  without it, just later.

### Misc
* `IcyStreamReader` closes the previous `HttpClient` on each attempt. Every
  attempt created one and `stop()` closed only the last.
* `AudioProxyServer.stop()` closes its `_queue` stream controller, which was
  never closed.
* `icy-metaint` is no longer an instance field but read per response, so two
  connections can no longer desynchronise the audio / metadata split.
* A `stop()` during an active read no longer leaves the read suspended for
  ever (cancelling a subscription fires neither `onDone` nor `onError`).
* New test bench `test/stream_reconnect_test.dart` covering the reconnection
  policy and the generation token against a local ICY server.

### Platforms
* No native change — the Android side was not at fault.
* The web implementation is unchanged: the platform interface surface did not
  move (`retryNow` and `PlayerInterrupted` both live in the Dart layer).

## 0.1.4

### Maintenance
* Android toolchain updated to the versions tested with Flutter 3.44.6:
  Android Gradle Plugin 9.2.1 and Kotlin 2.4.10. The Kotlin Gradle Plugin (KGP)
  compatibility warnings emitted by earlier Flutter versions are now gone.
* Native dependencies bumped: Media3 1.10.1, androidx.core-ktx 1.19.0,
  kotlinx-coroutines 1.11.0, and Mockito 5.23.0 (tests).
* Dart dependencies bumped: web 1.1.1, plugin_platform_interface 2.1.8,
  http 1.6.0, path_provider 2.1.6.

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
