# SwitzachWidgetProbe

Home screen widgets for sideloaded apps on Switzach — the way iOS does them.

Apps you install in the Switzach ROM ship their own WidgetKit extensions, but the ROM's home
screen has nothing that runs them. SwitzachWidgetProbe loads each app's widget extension inside
SpringBoard and draws the widgets with the app's own SwiftUI code.

How it works, and what it can and cannot do in detail: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Features

- **Widget gallery** — the home screen's **+** button › **Add Widget** opens an iOS-style
  gallery: one suggested widget per app, the list of apps with widgets, and search. An app's
  page shows each of its widgets in each of its sizes, with names and descriptions.
- **Sizes** — small, medium and large, as each widget declares (Lock Screen–only widgets are
  left out).
- **Stacks** — widget stacks you swipe through, with page dots; the shown widget is remembered.
- **Removal** — the − badge in edit mode, or the long-press menu, with the iOS confirmation.
- **Live updates** — widgets refresh on their timeline and when the app changes its shared data.
- **Interactive widgets** — buttons run the app's intent. Actions that iOS performs
  inside the app (`openAppWhenRun`, `ForegroundContinuableIntent`, `LiveActivityIntent`,
  `AudioPlaybackIntent`, `PushToTalkTransmissionIntent`) open the app instead. Small buttons
  take taps within a 44 pt target, as on iOS.
- **Links** — a widget's links open the app at the right place (`SwitzachWidgetLinks`, loaded
  into apps, hands the URL over).
- **Translated texts** — texts the system looks up while drawing (SwiftUI `Text("key")`,
  `String(localized:)`) are found in the widget's own strings.
- **Crash guards** — if a widget's button, configuration or data loading crashes, that part is
  stopped instead of taking SpringBoard down again. If SpringBoard keeps crashing right after
  launch, widgets are not drawn for one launch so they can be removed.

## Requirements

- Switzach with ElleKit (tweak injection)
- `preferenceloader` (installed automatically as a dependency)
- TweakSettings, for the settings page (optional: the defaults need no setup)

## Install

Download the `.deb` from [Releases](https://github.com/Aquaappl/switzachwidgetprobe/releases)
(or build it, below) and install it with your package manager (for example Sileo), then
respring.

A release is published automatically whenever the package version goes up
(`.github/workflows/release.yml`).

## Settings

TweakSettings › **SwitzachWidgetProbe**:

| Setting | Default | |
| --- | --- | --- |
| Reset Widget Safety Guards | — | Tries the widget parts that were stopped after a crash again. |
| Diagnostic Log | Off | Writes a detailed log to `Library/Caches/SwitzachWidgetProbe/runtime.txt` in the home screen's folder. Crashes are always recorded there. |

## Limitations

- An action that iOS runs inside the app (see above) opens the app; the action itself is not
  performed. Switzach has no system service to hand the action to the app.
- Widgets that need the app's live process (or system services Switzach does not provide) may
  stay on their placeholder.
- Configurable widgets use their default configuration.

## Build

```sh
SDK=/path/to/iPhoneOS16.5.sdk ./build.sh
```

Needs clang and lld (LLVM), an iOS SDK with the private `Preferences` framework (for example
`theos/sdks/iPhoneOS16.5.sdk`) and `dpkg-deb`. The package is written to `build/`.

## Layout

| Path | |
| --- | --- |
| `src/Tweak.m` | Entry point in SpringBoard; the **+** menu's Add Widget |
| `src/WPHome.m` | Home screen integration: widget icons, stacks, gallery, removal, taps |
| `src/WPProbe.m`, `src/WPProbe.h` | Finding, loading and rendering widget extensions (Swift runtime, WidgetKit) |
| `src/WPAsync.s` | Calling Swift `async` functions |
| `src/WPSettings.m` | Settings and the safety-guard reset |
| `src/WPLinks.m` | `SwitzachWidgetLinks`, loaded into apps: receives widget links |
| `prefs/` | The settings page (PreferenceLoader bundle) |
| `layout/` | Package metadata and injection filters |
