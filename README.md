# SwitzachWidgetProbe

Home screen widgets for sideloaded apps on Switzach — the way iOS does them.

Apps you install in the Switzach ROM ship their own WidgetKit extensions, but the ROM's home
screen has nothing that runs them. SwitzachWidgetProbe runs each app's widget extension in a
process of its own — as iOS does — and draws the widgets with the app's own SwiftUI code; the
home screen shows what that process drew. No app code runs inside SpringBoard.

3.x is a rewrite of 2.x for the ROM's iOS 27 home screen, with the icon style built in from
the start.

## Features

- **Widget gallery** — the home screen's **+** button › **Add Widget**: one suggested widget per
  app, the apps with widgets, and search. An app's page shows each of its widgets in each size.
- **Sizes** — small, medium and large, as each widget declares; change them from the long-press
  menu or by resizing in edit mode.
- **Stacks** — drop a widget on another of the same size; swipe through them. **Edit Stack**
  reorders or removes the widgets of a stack.
- **Edit Widget** — the settings of a widget that has them, for widgets configured with SiriKit
  intents (choices given by the app's Intents extension) or AppIntents (switches, numbers, text
  and lists). Each widget keeps its own settings.
- **Icon style** — colored, dark, clear and tinted icons: with clear and tinted icons, widgets
  sit on Liquid Glass in the icon tint and are drawn in WidgetKit's accented mode. They follow
  a style change at once, also while being resized.
- **Long-press menu** — as on iOS: Edit Widget, the sizes, Edit Stack, Edit Home Screen, Remove.
- **Removal** — the − badge in edit mode or the long-press menu, with the iOS confirmation.
- **Live updates** — widgets refresh on their timeline and when the app changes its shared data.
- **Interactive widgets** — buttons run the widget's intent. Intents that iOS runs in the app's
  process open the app.
- **Links** — a widget's links open the app at the right place (`SwitzachWidgetLinks`, loaded
  into apps, hands the URL over).
- **Crash isolation** — a widget that crashes ends only its own process, which is started again;
  SpringBoard stays up. A part that keeps crashing is stopped (reset it in the settings).

## Requirements

- Switzach with ElleKit (tweak injection)
- `preferenceloader` (installed automatically as a dependency)
- TweakSettings, for the settings page (optional: the defaults need no setup)
- Nyxian's “Filesystem Sandbox” (recovery settings) **off**: with it on, the widget processes
  cannot read the apps' widgets. The Add Widget sheet and the widgets say so.

## Install

Download the latest `.deb` from
[Releases](https://github.com/Aquaappl/switzachwidgetprobe/releases) and install it with your
package manager (for example Sileo), then respring.

## Settings

TweakSettings › **SwitzachWidgetProbe**:

| Setting | Default | |
| --- | --- | --- |
| Restart Widgets | — | Starts every widget's process again and draws the widgets anew. |
| Reset Widget Safety Guards | — | Tries the widgets and widget parts that were stopped after a crash again. |
| Diagnostic Log | Off | Writes a detailed log to `Library/Caches/SwitzachWidgetProbe/runtime.txt` in the home screen's folder. Crashes are always recorded there. |

## Limitations

- An intent that iOS runs in the app's process opens the app; the intent itself is not
  performed (Switzach cannot run an app in the background).
- Widgets that need the app's live process, or system services Switzach does not provide, may
  stay on their placeholder.
- Edit Widget cannot yet change a setting whose choices are the app's own items (AppEntity);
  it shows them.
- The preview that follows the finger while a widget is dragged may not show the widget.

## Build

```sh
SDK=/path/to/iPhoneOS16.5.sdk ./build.sh
```

Needs clang and lld (LLVM), an iOS SDK with the private `Preferences` framework (for example
`theos/sdks/iPhoneOS16.5.sdk`) and `dpkg-deb`. The package is written to `build/`.

## Layout

| Path | |
| --- | --- |
| `src/springboard/` | SpringBoard: widget icons and stacks, the gallery, the long-press menu, Edit Stack and Edit Widget, the glass, starting and talking to the widget hosts, settings |
| `src/host/` | `SwitzachWidgetHost`, one process per widget extension: loads it, renders its widgets (Swift runtime, WidgetKit), runs taps, reads and saves widget settings |
| `src/links/` | `SwitzachWidgetLinks`, loaded into apps: receives widget links |
| `src/common/` | Shared by both sides: the extension model, messages, logging, crash markers |
| `host/` | The widget host app's Info.plist |
| `prefs/` | The settings page (PreferenceLoader bundle) |
| `layout/` | Package metadata and injection filters |
