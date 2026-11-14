## 0.1.9

### Fixed — the manufacturer's panel was invisible, so the plugin kept its own
* Detection used `resolveActivity`, which since Android 11 (API 30) only
  returns activities the app is allowed to see. Without a `<queries>`
  declaration the manufacturer's equalizer activity is invisible, the call
  returns null, and the plugin concludes there is no system equalizer — then
  attaches its own. On a Galaxy A25 the routing therefore always fell back to
  the plugin branch, audibly, while the device's panel did nothing.
* The plugin's manifest now declares visibility for
  `android.media.action.DISPLAY_AUDIO_EFFECT_CONTROL_PANEL`; the block is
  merged into the host application's manifest.
* The result is memoised: it depends only on installed packages and `Build`
  fields, neither of which change during the process. Without that, the
  `PackageManager` query ran on every `equalizerBackend()` call — so on every
  `STATE_READY`, that is on every station change — and the log line repeated.
* Detection uses `queryIntentActivities` rather than `resolveActivity`: when
  several activities answer, `resolveActivity` returns the system chooser — or
  null — whereas the question is only whether anything answers at all. What
  answered is logged, so an empty result points at the manifest rather than at
  the device.

### BREAKING
* On a device that exposes its own equalizer panel, the plugin now **defers to
  it** and attaches no `Equalizer` effect of its own. `equalizer.apply()` has
  no effect there, and the host must offer a button calling
  `equalizer.openSystemPanel()` instead of its own sliders. Query
  `equalizer.backend` to know which. Pass `preferSystemEqualizer: false` to
  `RadioService` to keep the old behaviour everywhere.
* `RadioServicePlatform.configure()` gains a `preferSystemEqualizer` parameter;
  any custom platform implementation must declare it.

### Added — equalizer routing
* New sealed class `EqualizerBackend`, with `EqualizerSystem`,
  `EqualizerPlugin` and `EqualizerUnavailable(reason)`. Sealed rather than an
  enum, for the same reason as `PlayerState`: an exhaustive switch in the host
  stops compiling when a member is added, and the carried reason says *why*
  there is no equalizer.
* `equalizer.backend` — resolved once and memoised; `equalizer.openSystemPanel()`
  opens the manufacturer's panel for the player's audio session.
* Detection does not look at the brand. It asks the system whether an activity
  answers `ACTION_DISPLAY_AUDIO_EFFECT_CONTROL_PANEL` — a question about a
  capability, which ages well.
* The plugin now broadcasts `ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION` when the
  audio session becomes valid and `ACTION_CLOSE_...` on release, so the
  device's equalizer applies to *our* stream rather than to a global setting.
  Opening the panel alone would not have been enough.

### Changed — one button, and no choice handed to the listener
* The example now shows a single **Égaliseur** button. Behind it: the
  manufacturer's panel where one exists, the plugin's sliders in a sheet
  otherwise. Same label, same gesture, whatever the handset. When no equalizer
  is available at all, there is no button rather than a disabled one with an
  explanation.
* An earlier iteration offered a "doesn't work? use the app's one" fallback
  link beneath the button. That pushed the plugin's own uncertainty into the
  interface — the listener had to diagnose and correct a bet the code had made.
  A button either works or is not shown.

### Note for developers — the Android emulator
* `preferSystemEqualizer` defaults to `true`, which is right on a real
  handset: verified on a Galaxy A25, where the manufacturer's panel opens and
  its controls genuinely change the sound.
* Emulated environments are excluded by the plugin itself. They answer the
  panel intent with an activity that opens and closes without setting
  anything, so delegating there means a dead button. There is no official API
  for this — Android Studio reads the same `Build` properties over adb — so
  the check uses the stable, documented signals (`Build.HARDWARE` of `goldfish`
  / `ranchu` / `vbox86` / `android_x86`, a generic or emulator fingerprint, an
  SDK product name, a `Build.DEVICE` starting with `emu`, Genymotion). It is a
  convenience, not a security control, and it is trivially bypassed — which is
  fine, that is not its purpose.
* The device identity actually read is logged on one line, in the same shape
  Media3 uses for its own `MediaSessionImpl` init line, plus `HARDWARE` and
  `PRODUCT`. A handset that slips through the check therefore diagnoses
  itself: the log says which values were seen, and they only have to be
  compared with the list of signals above.
* An unrecognised emulator falls through to the previous behaviour, and
  `equalizer.useBuiltIn()` remains the escape — a host tool, never a control to
  put in front of the listener.

### Fixed — obsolete `package` attribute in the manifest
* Removed `package="…"` from the plugin's `AndroidManifest.xml`. Since AGP 8
  the module's identity comes from `namespace` in `android/build.gradle.kts`,
  where it is already declared; keeping both is redundant and confuses the
  IDE's manifest validation. Relative class names (`.RadioMediaService`) still
  resolve against the namespace at merge time.

### Added — a way to overrule the detection
* `equalizer.useBuiltIn()` switches to the plugin's equalizer for the rest of
  the session and attaches it immediately, even mid-playback.
* It exists because **answering the intent does not prove the panel works**.
  Some system images — the Android emulator among them — expose an activity
  that opens and closes again without setting anything, and no API tells you
  beforehand. Detection is a presumption at best; the host must be able to
  contradict it at runtime, or the listener is left with a button that does
  nothing and no sliders to replace it.
* Detection also now ignores activities from the host's own package and any
  that are disabled or not exported.
* The example offers the fallback as a link under the system button.

### Why
* The standard Android effect bundle subtracts headroom proportional to the
  largest positive gain requested, to avoid clipping. A preset raising bass by
  6 dB therefore drops the whole output by about as much: the curve is right,
  the level has fallen, and a boost is heard as an attenuation. Measured on a
  Galaxy A25 with every manufacturer effect switched off — flat was the
  loudest setting, and +6 dB on all five bands was barely louder than flat,
  which is exactly what that model predicts.
* A manufacturer's equalizer has more bands, is tuned for that speaker, and is
  set with the right headroom. Where the device knows better, the plugin gets
  out of the way rather than stacking a second processor in series.
* What this costs, and it is deliberate: on those devices the setting belongs
  to the phone. The plugin can neither read it, nor remember it, nor restore
  it, and the host shows a different control depending on the handset.

## 0.1.8

### Fixed — unplugging headphones left the radio stuck reconnecting
* `setHandleAudioBecomingNoisy(true)` let ExoPlayer pause itself **without
  telling Dart**. The Dart layer kept its upstream connection open for a player
  that had stopped reading; the link eventually expired and the reader looped
  on reconnection (`PlayerInterrupted`) with no way out — closing the app was
  the only recovery, and changing station did not help.
* The plugin now owns that broadcast: `setHandleAudioBecomingNoisy(false)` plus
  an `ACTION_AUDIO_BECOMING_NOISY` receiver registered on `play()` and released
  on `pause()`, `stop()`, `release()` and on the pause itself. The receiver is
  registered through `ContextCompat.registerReceiver` with
  `RECEIVER_NOT_EXPORTED`, mandatory from Android 14 (API 34) — a bare
  `registerReceiver()` throws there.
* A **permanent** loss of audio focus (`AUDIOFOCUS_LOSS`) takes the same route.
  `RadioAudioFocusManager` gains an `onPermanentLoss` callback, distinct from
  `onPause`, because the two need opposite treatment downstream: a transient
  interruption must keep the source ready so automatic resume stays instant, a
  permanent one must release it. One callback for both could not tell them
  apart.
* New native event `externalPause` (reason: `noisy` or `focusLoss`), surfaced
  as `RadioServicePlatform.externalPauseStream`. `RadioService` subscribes to
  it and runs exactly the explicit-pause path — without asking the native side
  to pause again, since it already has. The next `play()` reloads the station.
* This closes the gap documented as "Known gap — focus-driven pauses" in 0.1.7.

### Fixed — equalizer bands were applied by position, not by frequency
* `RadioEqualizer.apply()` wrote `gains[i]` into hardware band `i`, assuming
  five bands at 60 / 230 / 910 / 3600 / 14000 Hz. The band count and centre
  frequencies are device-dependent: 3, 5, 6, 8 or 10 bands, centred elsewhere.
  On a ten-band device the "treble" gain landed around 500 Hz and every band
  above 1 kHz was forced flat — an unintended low-pass. Presets came out
  almost inaudible, and boosts could read as attenuation.
* The five gains are now interpolated onto each band's **real** centre
  frequency, on a log scale because that is how pitch is perceived. Outside the
  nominal range the end value is extended rather than dropping to zero, so a
  device whose last band sits at 16 kHz still follows the treble slider.
* On a device that does expose the five nominal frequencies, the interpolation
  returns the input gains exactly — verified numerically. The fix changes
  nothing where the equalizer already behaved correctly.

### Added — equalizer diagnostics
* `RadioEqualizer` dumps the device's equalizer profile once on creation: audio
  session id, enabled state, band count, level range, and for each band its
  centre frequency, its frequency span and its current level. It also lists the
  manufacturer presets and every audio effect the system exposes
  (`AudioEffect.queryEffects()`).
* `apply()` now reads the levels back after writing them. What the device keeps
  can differ from what was asked — quantisation, clamping, or a vendor
  implementation — and the readback is the only way, short of a measurement, to
  tell "the plugin asks wrongly" from "the device does something else with the
  request".
* Both go to logcat under the `RadioEqualizer` tag. Comparing the block between
  two handsets answers in one read why the same setting does not sound the same
  on both.

### Fixed — the equalizer setting was lost on every station change
* `setUrl()` releases the equalizer (the audio session id changes with the
  stream) and cleared `pendingEqualizer` with it. A setting sent *before*
  `setUrl` was therefore dropped, and the host had to resend it after every
  load for it to stick.
* `RadioExoPlayer` now keeps a `lastEqualizer` that survives station changes
  and is reapplied when the new session reaches `STATE_READY`. It is cleared
  by `resetEqualizer()`, by `configure(equalizerEnabled: false)` and by
  `release()` — not by `setUrl()`.

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
