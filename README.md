# DictationIsland

Voice dictation that lives in your MacBook's notch. Hold a key and talk: the island grows out of
the notch with a live transcript, and when you let go the text is pasted wherever your cursor is.
Everything runs on-device.

![DictationIsland demo](docs/demo.gif)

<p align="center"><img src="docs/states.png" width="520" alt="Listening, finishing and pasted states"></p>

## Install

Requires **macOS 26** or later. Works best on a Mac with a notch; other displays get a pill in
the menu bar.

### Download

1. Download `DictationIsland-<version>.dmg` from the
   [latest release](https://github.com/BinhL3/DictationIsland/releases/latest).
2. Open it and drag **DictationIsland** into **Applications**.
3. Open it from Applications. The app isn't notarized by Apple, so the first launch is blocked:
   go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   (Or run `xattr -dr com.apple.quarantine /Applications/DictationIsland.app` once.)
4. A short setup walks you through two permissions, **Microphone** and **Accessibility**
   (for the dictation key and pasting), while the speech model downloads, then lets you try a
   dictation. A small guide docks under System Settings showing what to drag where.
   Optional later: **System Audio Recording** (muffle music while you talk) and
   **Screen Recording** (annotations).

### Build from source

Needs Xcode 26 (Swift 6.2).

```bash
git clone https://github.com/BinhL3/DictationIsland.git
cd DictationIsland
make install     # build, sign, install to /Applications, launch
```

`make install` signs with a self-signed certificate it creates once in its own keychain
(`scripts/signing.sh`), so macOS keeps your permission grants across rebuilds.
`make dmg` builds `build/DictationIsland-<version>.dmg`.

## Using it

* **Hold to talk.** Hold a push-to-talk key, speak, release. The text is pasted into the focused
  app and also left on the clipboard. **Tap** the key instead for hands-free mode; tap again to
  finish. Defaults to **fn** and **right ⌥**; add or change keys in Settings → General. Using the
  key in a shortcut (like right ⌘C) doesn't start a dictation.
  If you use fn, set System Settings → Keyboard → "Press 🌐 key to" → *Do Nothing*.
* **Hover** the island while dictating to see the whole transcript, with Cancel and Done.
* **⌃⌥Space** is an optional backup shortcut that needs no permissions (off by default).
* **Formatting**: say "new line", "new paragraph" or "bullet point". Bullets paste as a real list
  in Notes, Mail, Docs and Slack.
* **Words** (Settings → Writing): fix things it keeps mishearing (`get hub -> GitHub`) and teach it
  names.
* **Writing style** (Settings → Writing, optional): tidies each dictation with Apple Intelligence's
  on-device model, removing ums and false starts and following a description of how you write.
* **Annotate for AI agents**: tap **⌃⌥A**, talk through what's on screen and hold **⇧** to draw on
  it, tap ⌃⌥A again. You get screenshots of each moment, a timestamped transcript and the video,
  with a message ready to paste into Claude Code or another agent.
* **History**: the last 100 dictations are in Settings → History.
* **Updates**: once a day the app asks GitHub whether a newer release exists (one request to the
  public releases API; nothing about you is sent). If so, Home shows a Download button. Drag the new
  version into Applications; settings and permissions carry over.
* Open Settings from the menu bar 〰 icon, or by opening the app again.

### Speech engines (Settings → Speech)

| Engine | Notes |
|---|---|
| **Apple Speech** | Apple's newest on-device model (`SpeechTranscriber`). |
| **Apple Dictation** | The model behind macOS keyboard dictation (`DictationTranscriber`). |
| **Underdog Bark 3.0** | Parakeet V3 post-trained for English: as accurate overall, better on conversational speech. One-time ~200 MB download, runs on Core ML. The first load compiles it for the Neural Engine, which takes several minutes. |
| **NVIDIA Parakeet V3** | 25 European languages, auto-detected. One-time ~630 MB download, runs on Core ML. |
| **Legacy** | `SFSpeechRecognizer`. |

*Automatic* picks the best Apple model for your language.

### Other settings

* **Muffle media while dictating**: music and video get a DJ-style low-pass sweep while you talk
  (needs System Audio Recording), or the output volume fades down instead. Only kicks in when
  something is playing.
* **Microphone**: pick any input, and for stereo mics like the Blue Yeti, which channel to use.
  *Test Microphone* shows live levels. Mics hidden by a leftover driver extension (e.g. Logitech
  G HUB's "Blue Voice") are still found and listed.
* **Placement**: in the notch (or a menu bar pill), or below the menu bar. If you run another notch app such as Alcove,
  DictationIsland draws over it while you dictate and stays out of its way otherwise.
* **Open at login** (install to /Applications first).

## Development

```bash
make run         # build and run from build/
make demo        # UI demo loop, no mic needed
open build/DictationIsland.app --args --state compact|peek|expanded|finishing|done|error
open build/DictationIsland.app --args --record "Some text"   # one scripted dictation that pastes, then quits
```

`--simulate-notch` lays the island out as if the screen had a notch.

| File | Role |
|---|---|
| `IslandModel.swift` | State machine (`DictationPhase`) → derived `Presentation`, sizes, radii, animations |
| `IslandView.swift` | Island shell, wings, live transcript line, expanded body |
| `IslandPanel.swift` | Non-activating fixed-canvas panel, hover/click-through, layering with other notch apps |
| `WindowSpace.swift` | Private window-server space with an absolute level, so the island draws above menu bar apps |
| `NotchGeometry.swift` | Notch vs pill detection, `NotchShape` |
| `Motion.swift` | Shared springs and transitions |
| `WaveformView.swift` | Bar waveform (live/simulated/suspended), recording dot, shimmer |
| `AudioCapture.swift` | Chosen input → mono downmix (channel select) → FFT → voice bands; prepared engine for fast starts |
| `Transcriber.swift` | `Transcriber` protocol + legacy `SFSpeechRecognizer` engine |
| `SpeechAnalyzerTranscriber.swift` | `SpeechAnalyzer` engines (Apple Speech / Apple Dictation), model install, engine resolution |
| `LocalModels.swift` | Shared by the downloaded engines: pinned Hugging Face downloads, live re-decoding, pause-aligned 15 s segments |
| `Parakeet.swift` | Parakeet TDT 0.6B v3 on Core ML: model files, TDT greedy decode |
| `Bark.swift` | Bark 3.0: Core ML encoder, mel frontend and TDT decoder ported from the reference Python, `.npz` reader |
| `MediaMuffler.swift` | Process tap + aggregate device + realtime low-pass sweep; volume-fade fallback with crash-safe restore |
| `TextInserter.swift` | Clipboard + synthetic ⌘V |
| `ModifierKeyTrigger.swift` | Multi-key push-to-talk (fn / any modifier side) via a listen-only event tap; ignores chords |
| `HotKey.swift` | Optional ⌃⌥Space backup shortcut |
| `AppSettings.swift` | Preferences (UserDefaults) and dictation history |
| `AudioDevices.swift` | Core Audio input device list (name, UID, channel count) |
| `Permissions.swift` | Status and grant flow for the permissions |
| `SettingsView.swift` | Settings window: General, Speech, Microphone, Permissions, History |
| `scripts/` | `bundle.sh` (app), `install.sh`, `dmg.sh`, `signing.sh` (local identity), `make-icon.swift` |

## Credits

Onboarding, the permission guide, annotations, the release tail and several reliability fixes
follow ideas from [Hex](https://github.com/anomalyco/hex) (MIT); no Hex code is included.

Inspired by the notch UI of [Alcove](https://tryalcove.com). DictationIsland is an independent
project, not affiliated with or endorsed by Alcove, and contains none of its code or assets.

Parakeet V3 weights: NVIDIA (CC-BY-4.0), Core ML export by FluidInference
(`FluidInference/parakeet-tdt-0.6b-v3-coreml`). Bark 3.0 weights: Conway Research
(`ConwayResearch/Underdog-Bark-3.0`, CC-BY-4.0), derived from NVIDIA's Parakeet TDT 0.6B v3 and
Moondream's parakeet-ultra. Process-tap setup follows insidegui/AudioCap.

## License

MIT, see [LICENSE](LICENSE). The Parakeet and Bark models are downloaded separately and stay under
their own CC-BY-4.0 licenses.
