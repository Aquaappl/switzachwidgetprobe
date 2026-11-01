# How SwitzachWidgetProbe works

SwitzachWidgetProbe runs each sideloaded app's own WidgetKit extension inside SpringBoard and
puts its widgets on the Switzach home screen the way iOS does. What a widget shows, and the
data behind it, come from the app's own SwiftUI code; the tweak stands in for the iOS system
services (WidgetKit's host, chronod, linkd) that Switzach does not have.

The tweak is loaded into SpringBoard (and, for links, into apps) by ElleKit, through the usual
`Library/MobileSubstrate/DynamicLibraries` filters. Switzach does not allow patching code, so
ElleKit's function hooks are not used: everything is hooked through the Objective-C runtime
(`method_setImplementation`).

This document describes version 1.0.3.

## At a glance

```
SpringBoard (SwitzachWidgetProbe.dylib)                      Each app (SwitzachWidgetLinks.dylib)
├─ Tweak.m      entry point, "+ > Add Widget"                └─ WPLinks.m  receives widget links
├─ WPHome.m     home screen: icons, stacks, gallery,                      and hands the URL to the app
│               removal, taps, refreshes
├─ WPProbe.m    finds, loads and renders widget extensions   TweakSettings
│  └─ app's widget extension (.appex), loaded with dlopen    └─ SwitzachWidgetProbePrefs.bundle
├─ WPAsync.s    calls Swift async functions                     settings page
└─ WPSettings.m settings, safety-guard reset  ◄── settings file + Darwin notification ──┘
```

## What it can do

| Feature | How to use it | Notes |
| --- | --- | --- |
| Add widgets | Home screen **+** › **Add Widget** | An iOS-style gallery: one suggested widget per app with a live preview, the list of apps with widgets, search; an app's page shows all its widgets and sizes with names and descriptions |
| Sizes | Pick small / medium / large in the gallery | Only the sizes the widget declares. Lock Screen–only widgets are not listed |
| Stacks | Several widgets in one place | Swipe through, with page dots; the shown widget is remembered |
| Removal | The − badge in edit mode, or the long-press menu | The iOS confirmation ("Remove “…” Widget?") |
| Automatic updates | Nothing to do | At the timeline's next date, when the app writes its shared data, and after a button |
| Buttons | Tap a button in a widget | Actions that finish inside the widget run in place. Small buttons take taps within a 44 pt target |
| Actions iOS runs inside the app | Same | Open the app instead (see the limits below) |
| Links | Tap a link in a widget | Opens the app and hands it the URL (e.g. YouTube's Subscriptions) |
| Open the app | Tap anywhere else | Opens the widget's app |
| Restoring after a respring | Nothing to do | Places, sizes and stack order come back |
| Crash guards | Nothing to do | Only the part that crashed is stopped; reset in the settings |

## What it cannot do

Where iOS relies on a system service that Switzach does not have, the feature cannot work.

| Limitation | Why | What happens instead |
| --- | --- | --- |
| Completing an action that iOS performs inside the app | iOS performs `openAppWhenRun`, `ForegroundContinuableIntent`, `LiveActivityIntent`, `AudioPlaybackIntent` and `PushToTalkTransmissionIntent` actions in the app's process, handed over by linkd. Switzach has no linkd; handing the action to the app ourselves ended in `intentNotFound` | The app is opened. Example: the check button of a to-do app |
| Lock Screen, StandBy and Notification Center widgets | Only the home screen is covered | Lock Screen–only widgets are not offered |
| Control Center controls, Live Activities | Different mechanisms (ControlWidget, ActivityKit) | Not supported |
| Editing a widget's configuration | No configuration UI yet | Configurable widgets use their default configuration |
| Widgets that need the app's live process or a system service Switzach lacks | The extension runs inside SpringBoard, not in a real extension process | The widget may stay on its placeholder |
| Push updates from a server; `WidgetCenter.reloadTimelines` from the app as such | Switzach has no chronod | Changes to the app's shared data are watched instead, which has nearly the same effect |
| An updated app's extension, right away | The extension runs from a signed copy | The new build is copied again on the next respring |

## 1. Loading an extension

The heavy steps run on a background queue, so the home screen does not freeze.

1. **Find** — List installed apps with `LSApplicationWorkspace` and look in each app's
   `PlugIns` for `NSExtensionPointIdentifier` = `com.apple.widgetkit-extension`.
2. **Copy and sign (background)** — Copy the extension to
   `Library/Caches/SwitzachWidgetProbe/runtime-<extension id>` and sign it with Nyxian's signing
   call. If the executable's size and modification date match the last copy, that copy is reused.
3. **Preload frameworks (background)** — Load the frameworks the extension links through
   `@rpath` (e.g. RealmSwift) from the app's `Frameworks` first.
4. **dlopen (background)** — Load the extension's executable into SpringBoard. Steps 2–4 took
   30–530 ms on a device with the earlier copy reused (copying and signing a new build takes
   longer, once).
5. **App Groups** — Find the extension's App Groups from its entitlements and the `group.…`
   strings in its binaries (cached). Switzach has no shared containers, so
   `containerURLForSecurityApplicationGroupIdentifier:`, `NSUserDefaults(suiteName:)` and
   CFPreferences are redirected to the app's own data container. The widget then reads the same
   data as the app.
6. **Bundle.main** — When called from the extension's code, `Bundle.main` returns the
   extension's bundle, so its images and localized strings are found. Some texts are looked up
   by the system's code instead, while the widget is drawn — SwiftUI's `Text("key")` and
   `String(localized:)` — and those go to SpringBoard's bundle. For the two `NSBundle` methods
   they use (`localizedAttributedStringForKey:value:table:localization:` and
   `_localizedStringForKey:value:table:localizations:`), a key that SpringBoard's bundle does
   not have is looked up in the loaded extensions' bundles too.
7. **Read the widgets (main thread)** — Find `WidgetBundle` / `Widget` in the extension's Swift
   type information (the `__swift5_proto` conformance records), run the app's `init()` and
   `body`, and walk the configuration tree. For each widget this yields its kind, its timeline
   provider (`TimelineProvider`, `IntentTimelineProvider` or `AppIntentTimelineProvider`), the
   function that builds its view, and its name, description and supported sizes. This took
   22–155 ms on a device.

A `WidgetBundle`'s `body` is main-actor isolated, so step 7 cannot move to a background thread.
It runs once per extension per launch.

## 2. Drawing and refreshing

The tweak calls the app's own code in the order WidgetKit does on iOS.

1. **Setup** — Build the `TimelineProviderContext` that WidgetKit would pass (family, size,
   …). A configurable widget gets its configuration type's default value (an `AppIntent`, or
   the Intents extension's `INIntent`), made once.
2. **Placeholder** — Only for the first drawing and when the size changes: `placeholder(in:)`
   is shown right away.
3. **Timeline** — Call `getTimeline` (for App Intents widgets the `async`
   `timeline(for:in:)`) and show the entry for the current time. Swift `async` functions are
   called through `WPAsync.s`.
4. **No answer** — After 10 s a snapshot is asked for as well; after 40 s the tweak gives up
   and keeps what is shown.
5. **Show** — The entry goes through the app's widget view into a `UIHostingController`, placed
   where the widget icon is.

What triggers a refresh:

| Trigger | When |
| --- | --- |
| Timeline | At the next entry's date (at least 60 s away), otherwise every 30 minutes |
| The app's data changed | The app's preferences folder and App Group folders are watched; refresh 1.5 s after a write (writes during the widget's own drawing, within 5 s, are ignored) |
| A button was tapped | 0.7 s and 2.5 s later |

On iOS, chronod refreshes a widget when the app calls `WidgetCenter.reloadTimelines`. Switzach
has no chronod, so "the app wrote its shared data" stands in for it.

## 3. Buttons and links

Buttons and links are found through SwiftUI's accessibility tree and run with the same
"activate" command VoiceOver uses.

**Buttons**

1. When the first widget is shown, accessibility is turned on in SpringBoard (without it,
   SwiftUI does not build the list of buttons).
2. The smallest button under the tap is used; if there is none, the nearest button within a
   44 pt target.
3. The extension's `Metadata.appintents` (the list of the app's actions) is read. If every
   button action is one that iOS performs inside the app, the app is opened instead.
4. Otherwise the button runs: SwiftUI's `Button(intent:)` performs the app's `perform()`
   through AppIntents inside SpringBoard — what iOS calls running in the extension's process.
5. The widget is refreshed afterwards.

**Links**

1. SwiftUI's `Link` asks `UIApplication` to open the URL. The tweak hooks that call and picks
   the app from the URL scheme (or the widget that was just tapped).
2. Switzach can open an app but cannot hand it a URL, so the URL is left in the app's data
   container (`Library/Caches/com.rinapple.widgetlink.plist`) and the app is opened.
3. `SwitzachWidgetLinks`, loaded into the app, checks for that file 0.4 s and 1.5 s after the app
   comes to the front, and hands a URL younger than 45 s to the app through
   `scene:openURLContexts:` (or `application:openURL:options:`) — the same entry iOS uses when it
   opens an app with a URL.

A tap anywhere else opens the widget's app.

## 4. The home screen

Widgets are the home screen's own widget icons; the tweak only draws what is inside them. Moving,
edit mode and icons making room work as the ROM does them.

- **Icons** — An `SBWidgetIcon` holding `SBHWidget`s (extension id, kind, app, sizes). The
  SpringBoardHome methods that ask for an icon's content view are hooked to return the tweak's
  view controller.
- **Labels** — On iOS chronod provides the label; on Switzach it stays "Waiting…", so the app's
  name is shown.
- **Stacks** — One `SBWidgetIcon` with several widgets. The view controller pages through them
  with page dots and records the shown one with `setActiveWidget:`.
- **Gallery** — "Add Widget" in the **+** menu opens an iOS-style sheet: one suggested widget
  per app at the top (only from apps already loaded, so opening the gallery runs no new app
  code), the apps with widgets, and search. An app's page shows all its widgets in each size. The chosen widget goes to the top of the current page and pushes the
  other icons along.
- **Removal** — The ROM shows the − badge only for apps; it is turned on for widgets as well,
  with the iOS confirmation before the widget is removed. The long-press menu asks the same.
- **After a respring** — The ROM writes widgets to `IconState.plist` but drops them again while
  importing it at launch (chronod does not know them). The tweak keeps its own record of where
  they were and puts them back after the import.

## Crash guards

The app's code runs inside SpringBoard, so a crash there takes SpringBoard down. Risky steps are
therefore marked before they run, and a step that crashed is not run again.

A marker is a file in the work folder. While a step runs, `<name>.running` holds SpringBoard's
process id; it is removed when the step ends. A later SpringBoard that finds an earlier process's
`.running` file knows that step crashed, turns it into `.bad`, and skips the step from then on.
A respring while a step runs counts the same way, so the windows are kept short.

| Guarded step | Marker | Removed | Once it crashed |
| --- | --- | --- | --- |
| A widget's buttons | `control2-<extension>-<kind>` | 5 s after the tap (the action runs asynchronously) | The buttons are not run; a tap opens the app |
| An App Intents widget's timeline (`async`) | `async2-<extension>-<kind>` | When the call returns and its entry is drawn (after 15 s if it never returns) | The placeholder stays |
| Reading names, descriptions and sizes | `descriptor-<extension>` | When the reading ends | The widgets are listed without them |
| The Intents extension's defaults | `intent-defaults-<extension>` | When they are made | Not used, and the Intents extension is not loaded (not reset by the reset) |

Also:

- **Launch guard** — If SpringBoard ends within 12 s of launch twice in a row (crashes, or
  resprings that soon), widgets are not drawn on the next launch, so the widget at fault can be
  removed.
- **Crash records** — Signals and exceptions are written to `runtime.txt`, with where they
  happened, even when the diagnostic log is off.

The Intents extension's defaults are never reset: loading a second copy of the app's code (such
as the app's own Firebase) into the same process cannot work.

## Settings and logs

The settings live in TweakSettings › **SwitzachWidgetProbe**, a PreferenceLoader bundle.

| Setting | Default | |
| --- | --- | --- |
| Reset Widget Safety Guards | — | Removes the crash markers (`.bad` / `.running`) so those parts are tried again |
| Diagnostic Log | Off | Writes a detailed log to `runtime.txt`. Turning it on also starts the main-thread stall watchdog, which runs until the next respring |

**How settings reach SpringBoard** — The values are stored in the `com.rinapple.switzachwidgetprobe`
domain, and a change posts the Darwin notification `com.rinapple.switzachwidgetprobe/settings`. On
Switzach a settings app may store the domain in its own data container, so SpringBoard reads
CFPreferences, its own `Library/Preferences`, and the data container of TweakSettings (and of
the Settings app, where there is one), and uses the newest. In case notifications do not
reach SpringBoard, it also checks those files' dates every 5 s.

**Logs** — In SpringBoard's `Library/Caches/SwitzachWidgetProbe/`:

- `runtime.txt` — activity and crash records; moved to `runtime-old.txt` past 1 MB.
- `report.txt` — details of loading extensions (with the diagnostic log on).
- `runtime-<extension id>/` — the extension's copy and caches.
- `*.running` / `*.bad` — crash markers.

## Changes in 1.0.3

- After a respring, widgets on a page that held only widgets ended up on another page (with
  the app icons pushed to the next page): SpringBoardHome drops that page together with the
  widgets while importing the layout, so the pages after it moved up. The page is now made
  again before the widgets are put back.

## Changes in 1.0.2

- The home screen asks a widget's view controller for `visibleBounds` (the part of the icon's
  content that shows) when edit mode starts. It is now answered with the widget's bounds;
  1.0.1 answered zero. No visible difference has been seen.

## Changes in 1.0.1

**Fixes**

- Texts that SwiftUI or `String(localized:)` look up while drawing (for example a to-do app's
  "Today") showed their key; they are now found in the extension's strings (step 6 above).
- An App Intents widget could stay on its placeholder for good after a respring within 15 s of
  drawing it: its crash marker was only removed after 15 s. It is now removed when the call
  returns.

**Performance**

| Change | 1.0.0 | 1.0.1 |
| --- | --- | --- |
| Placeholder on refresh | Every refresh drew the placeholder and then the entry | Only the first drawing and size changes; a refresh goes straight to the new entry (no flicker) |
| Overlapping refreshes | A button's two refreshes and a data change each fetched the app's timeline | Requests made while a fetch runs become one refresh after it |
| Widgets off screen | Refreshed right away, even on other pages | Wait until they are on screen (at most 60 s, so they never stop updating) |
| Intents extension switched off after a crash | Still loaded at every launch | Not loaded |
| Gallery suggestions | Up to 8 previews, often all from one app (each runs the app's code) | One per app |
| Main-thread stall watchdog | A timer woke SpringBoard every second | Only after the diagnostic log is turned on |

Measured on a device with 1.0.1: loading an extension 30–530 ms in the background (earlier copy
reused), reading its widgets 22–155 ms on the main thread, a refresh from request to the new
entry on screen typically under 250 ms (median 79 ms). Reading the widgets is the app's
`WidgetBundle`, which must run on the main thread; both happen once per extension per launch.

## Source layout

| File | Runs in | Role |
| --- | --- | --- |
| `src/Tweak.m` | SpringBoard | Entry point; "Add Widget" in the **+** menu |
| `src/WPHome.m` | SpringBoard | Home screen: icons, stacks, gallery, removal, taps, refreshes |
| `src/WPProbe.m`, `src/WPProbe.h` | SpringBoard | Finding, loading and drawing extensions (Swift runtime, WidgetKit), App Groups, crash guards and records |
| `src/WPAsync.s` | SpringBoard | Calling Swift `async` functions |
| `src/WPSettings.m` | SpringBoard | Reading the settings; resetting the crash guards |
| `src/WPLinks.m` | Each app | `SwitzachWidgetLinks`: receives a link's URL and hands it to the app |
| `prefs/` | TweakSettings | The settings page (PreferenceLoader bundle) |
| `layout/` | — | Package metadata and injection filters |
| `build.sh` | — | Builds everything and packages the `.deb` |
