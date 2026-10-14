# DictationIsland

A notch / menu-bar "island" UI for voice dictation, built on the patterns recovered from Alcove
(see `../research/alcove/REPORT.md`).

![demo](../research/alcove/screens/demo.gif)

## Install

```bash
make install     # build, sign, install to /Applications, launch
make dmg         # build/DictationIsland-<version>.dmg to share
make demo        # UI demo loop, no mic needed
```

Builds are signed with a local identity (`scripts/signing.sh` creates it once, in its own
keychain), so macOS keeps Microphone / Input Monitoring / Accessibility grants across rebuilds.
It's only trusted on this Mac; sharing the DMG with other Macs would need a Developer ID.
Requires macOS 26 or later.

* **Settings** opens on first launch (and whenever you open the app again from Finder/Spotlight,
  or choose *Settings…* in the menu bar 〰 icon). Tabs: General, Speech, Microphone, Permissions,
  History.
* **Speech engine** (Settings → Speech): *Apple Speech* (`SpeechTranscriber`, Apple's newest
  on-device model, macOS 26+), *Apple Dictation* (`DictationTranscriber`, the macOS keyboard
  dictation model), *NVIDIA Parakeet V3* (the model Handy and Noi recommend; 25 European
  languages, auto-detected; one-time ~630 MB download), or the legacy `SFSpeechRecognizer`.
  *Automatic* picks the best Apple model for your language. Everything runs on-device.
* **Muffle media while dictating** (Settings → General): with *System Audio Recording* allowed,
  other apps' audio is tapped and swept through a resonant low-pass, DJ-style, while you talk;
  without it, the output volume fades down instead. Only kicks in when something is playing.
* **Push-to-talk keys** (Settings → General): any number of keys, each modifier side separately
  or fn. *Add Key…* records the next one you press. Defaults to fn + right ⌥, so a Keychron at
  home and the MacBook keyboard both work without switching. Hold to talk, release to finish;
  tap for hands-free, tap again to finish. Shortcuts and characters typed with the key are
  ignored. Needs **Input Monitoring**. If you use fn, set System Settings → Keyboard →
  "Press 🌐 key to" → Do Nothing, or macOS will also act on it.
* **⌃⌥Space** is an optional backup (off by default) that needs no permission. Plain ⌥Space is
  left alone because Raycast uses it.
* **Microphone**: pick any input and, for stereo mics like the Blue Yeti, which channel to use
  (mix, left, right). *Test Microphone* shows live levels from the same capture path. Mics that
  a driver hides from macOS (e.g. a Blue Yeti behind Logitech G HUB's leftover "Blue Voice"
  extension) are found through the kernel audio driver and listed as "hidden by a driver".
* **Placement**: the island grows out of the notch (or a pill in the menu bar on displays without
  one). If Alcove is running it starts from Alcove's pill and draws over it while you dictate.
* **Open at login** in Settings → General (install to /Applications first).
* The text is always copied; with Accessibility granted it is also pasted into the focused app.
  The last 100 dictations are in Settings → History.

Requires macOS 26 or later.

UI iteration without a mic (`--simulate-notch` lays it out as if the screen had a notch):

```bash
open /Applications/DictationIsland.app --args --demo
open /Applications/DictationIsland.app --args --state compact|peek|expanded|finishing|done|error
```

## Layout

| File | Role |
|---|---|
| `IslandModel.swift` | State machine (`DictationPhase`) → derived `Presentation`, sizes, radii, animations |
| `IslandView.swift` | Island shell, wings, live transcript line, expanded body |
| `IslandPanel.swift` | Non-activating fixed-canvas panel, hover/click-through monitor |
| `WindowSpace.swift` | Private window-server space at absolute level 401, one above Alcove's 400, so the island draws over its pill |
| `NotchGeometry.swift` | Notch vs pill detection, `NotchShape` |
| `WaveformView.swift` | Bar waveform (live/simulated/suspended), recording dot, shimmer |
| `AudioCapture.swift` | Chosen input device → mono downmix (channel select) → FFT → 6 voice bands |
| `Transcriber.swift` | `Transcriber` protocol + legacy `SFSpeechRecognizer` engine |
| `Parakeet.swift` | Parakeet TDT 0.6B v3 on Core ML: pinned model download, TDT greedy decode, live re-decoding, pause-aligned 15 s segments |
| `MediaMuffler.swift` | Process tap + aggregate device + realtime low-pass sweep; volume-fade fallback with crash-safe restore |
| `SpeechAnalyzerTranscriber.swift` | `SpeechAnalyzer` engine (Apple Speech / Apple Dictation), model install, engine resolution |
| `TextInserter.swift` | Clipboard + synthetic ⌘V |
| `ModifierKeyTrigger.swift` | Multi-key push-to-talk (fn / any modifier side) via a listen-only event tap; ignores chords |
| `HotKey.swift` | Optional ⌃⌥Space backup shortcut with press/release |
| `scripts/` | `bundle.sh` (app), `install.sh`, `dmg.sh`, `signing.sh` (local identity), `make-icon.swift` |
| `AppSettings.swift` | Preferences (UserDefaults) and dictation history |
| `AudioDevices.swift` | Core Audio input device list (name, UID, channel count) |
| `Permissions.swift` | Status and grant flow for the four permissions |
| `SettingsView.swift` | Settings window: General, Microphone, Permissions, History |
| `Motion.swift` | Springs and transitions taken from Alcove's constants |

## Credits

Parakeet V3 weights: NVIDIA (CC-BY-4.0), Core ML export by FluidInference
(`FluidInference/parakeet-tdt-0.6b-v3-coreml`). Process-tap setup follows insidegui/AudioCap.

## License

MIT, see [LICENSE](LICENSE). The Parakeet model is downloaded separately and stays under its own
CC-BY-4.0 license.
