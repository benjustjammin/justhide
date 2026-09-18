<div align="center">
<img src="docs/icon.png" width="128" alt="JustHide">

# JustHide

**A small menu bar tidier for macOS 27.**

Pick the apps whose icons you don't need all the time. They disappear.
Click the chevron to bring them back.

<img src="docs/settings.png" width="520" alt="JustHide settings">
</div>

---

## Why this exists

macOS 27 rebuilt the menu bar, and it broke the trick every menu bar utility relied
on. Items are no longer separate windows, so nothing can enumerate them the old way,
and inflating a spacer to shove icons off the edge no longer works the way it used to.

JustHide doesn't fight that. It uses the concealment facility macOS 27 has built in, so
hiding is instant, nothing slides around, and the menu bar's layout is never touched.

It does one job. There is no floating bar, no icon previews, no groups, no profiles.

## Requirements

- macOS 27 (Golden Gate) or later
- No Screen Recording, no Developer ID, no sandbox exceptions
- Accessibility is **optional**, and asked for once on first launch.[^ax]

[^ax]: Hiding needs no permission at all. Accessibility buys two niceties: listing
which apps have menu bar icons right now, so the picker can show them, and checking
whether a newly launched app actually put an icon up before the allowlist is
refreshed. Refuse it and everything still works — you add apps from the same picker
or with **Other App…**. Settings shows an **Allow…** and a **Re-check** button while
it is missing, and both disappear once it is granted.

## Install

```sh
brew tap benjustjammin/tap
brew trust benjustjammin/tap      # Homebrew 7 will not load a cask from an untrusted tap
brew install --cask justhide
```

Releases are signed with a Developer ID and notarised, which matters for more than
Gatekeeper: macOS matches a permission grant against the app's signature, so a
properly signed build keeps your Accessibility permission across updates instead of
asking again every time.

Or build it — it takes a few seconds and needs only Xcode's command line tools:

```sh
git clone https://github.com/benjustjammin/justhide.git
cd justhide
./build.sh
cp -R build/JustHide.app /Applications/
open -a JustHide
```

Either way, a chevron appears in your menu bar. Install it somewhere inside an
Applications folder: macOS only honours the concealment allowlist for an app running
from one, so a copy left in `~/Downloads` or a build directory will look like it is
working and hide nothing.

> **Rebuilding?** `build.sh` ad-hoc signs by default, and an ad-hoc signature changes
> with every build — which quietly invalidates the Accessibility grant you just gave
> it, so the permission appears to come undone on its own. Make a self-signed
> certificate called `JustHide Dev` in Keychain Access (Certificate Assistant →
> Create a Certificate → Self Signed Root, Code Signing) and the script picks it up
> automatically, and the grant survives. `tccutil reset Accessibility dev.justhide.app`
> clears a stale entry if one gets stuck.

## Using it

- **Click the chevron** to show your hidden icons, click again to put them away.
- **Right-click it** for Settings and Quit.
- Set a **keyboard shortcut** in Settings if you'd rather not aim at the menu bar.
- Icons hide themselves again after a delay you choose, and never while your pointer
  is up in the menu bar.

In Settings, **+** opens a list of your apps with their icons: the ones with menu bar
icons right now first, then any that have had one before and are still running.
Search it, pick several at once, or use **Other App…** for something that isn't
running. **↻** re-reads the list — and the Accessibility permission with it.

JustHide never moves anything. Where each icon sits is macOS's business (see below),
so ⌘-drag them into the order you want and macOS will remember it.

## Good to know

Honest list of the things that will surprise you, all of them consequences of how
macOS 27 works rather than choices:

- **Hiding is per app, not per icon.** An app with several icons hides all of them
  together.
- **Position means nothing here.** A hidden icon is not moved to one side, it simply
  isn't drawn, so the JustHide symbol is not a boundary with hidden things behind it.
  Which side of it an icon sits on is macOS's choice, remembered per app — and it is
  remembered in *that app's* preferences, which is why the order never follows the
  order you opened things in. ⌘-drag is the only thing that changes it, yours or
  anyone's: no app can move another app's icon on macOS 27.
- **While icons are hidden, clicking the clock won't open Notification Center.**
  Swipe in from the right edge, or reveal first. Wi-Fi and Control Centre are
  unaffected.
- **This uses part of macOS that Apple doesn't document.** If an update breaks it,
  JustHide says so on its menu bar symbol and offers you the older layout-based
  method there and then — in the dialog, in the symbol's menu, and in Settings.
  Nothing is buried in the log.

## How it works

macOS 27 has an allowlist-based concealment facility — the one behind exam
"assessment mode". JustHide holds an assertion naming every running app *except* the
ones you've hidden, and macOS conceals the rest. Dropping the assertion reveals them.

Because it's an allowlist rather than a layout trick, there's no spacer item taking
up room, no icons sliding across the bar, and nothing to calibrate per display.

The allowlist is kept current rather than taken once. An app launched while icons are
hidden isn't on the list yet, and macOS would conceal it although you never asked —
so JustHide watches for new apps, waits until one has actually put an icon up, and
re-applies. Two details that took measuring: `NSWorkspace`'s launch notification never
fires for `LSUIElement` apps, which is exactly what a menu bar agent is, so the watch
is KVO on `runningApplications`; and the new assertion goes up *before* the old one
comes down, which reveals as cleanly as it conceals and leaves nothing to flicker.

The private surface it touches is small and loaded defensively — every class and
selector is checked before use, and it reports itself unavailable rather than
crashing if a future macOS moves things:

```
/System/Library/PrivateFrameworks/MenuBarClientCore.framework
  MBAssessmentModeConfiguration  -initWithAllowedSystemItems:allowedBundleIdentifiers:
  MBAssessmentModeAssertion      -activateWithConfiguration:completionHandler:
                                 -invalidate
```

The fallback is the older approach: inflate a divider so items overflow behind the
system's own chevron, with extra spacer items to cover a wider second display. It
works without any private API, at the cost of a gap in the bar and icons visibly
sliding on every toggle. It's kept because a private API can vanish in a point
release, and it is reached from the app: a refused or missing assertion marks the
symbol, offers the switch, and explains itself in Settings. `--width` runs it for one
launch without remembering the choice.

Its items — symbol, spacers, divider — are placed by CREATION ORDER, because
macOS puts a status item it has never seen before at the far left whatever order it
was made in. That is also the trap: how many spacers are needed depends on a length
calibration that isn't known until the first collapse, so a later launch can want a
spacer whose name has never existed — and that one lands left of the divider,
where its width does no pushing, silently, with icons leaking. So the count is pinned
per display arrangement. Needing more is recorded, applied at the next launch under a
fresh generation of names (which restores creation-order placement, at the cost of one
⌘-drag), and said out loud in Settings rather than left to the log.

## Updates

Settings says whether this is the latest version, next to a button to the project
page. Once a day, JustHide asks GitHub for the latest release and compares the tag
with its own version; if there is a newer one it says so in Settings and in the
symbol's menu. Nothing is sent -- no identifier, no version, no query string -- and
the switch in Settings turns it off.

It is not an updater. It offers the download, or for a Homebrew install the one
command that does the job properly:

```sh
brew upgrade --cask justhide
```

That distinction matters more than it looks: the cask quits the running copy before
replacing the bundle, and a copy that is holding a concealment assertion when its
bundle is swapped underneath it leaves the menu bar in whatever state it last
applied.

Diagnostics are deliberately readable, which is more than the mechanism it replaces
managed:

```sh
log show --last 5m --predicate 'subsystem == "dev.justhide.app"'
```

## Troubleshooting

`--simulate-unavailable` and `--simulate-failure` pretend the concealment facility is
gone or refuses, which is the only practical way to see what an unlucky macOS update
would look like.

`JustHide --list` prints your displays, every menu bar item it can see, and whether
Accessibility is granted. `JustHide --apps` prints what the app picker would offer you
and why. Both are the first things to run if something looks wrong, and the output is
safe to paste into an issue.

> **Don't judge the permission from a terminal.** macOS attributes a launch to the
> responsible process, so a JustHide started from a shell — `open` included —
> inherits *your terminal's* Accessibility grant and will cheerfully report
> `trusted: true` while the app itself has none. Launch it from Finder and read the
> notice in Settings instead. This cost me an hour and a wrong answer.

There are a few other diagnostic modes left in on purpose, because they are how the
behaviour above was established rather than guessed: `--tryassert <bundle-id>` holds a
concealment assertion for twelve seconds, `--tryclick [--cmd]` checks whether a
synthetic click reaches the menu bar, and `--trydrag` works through every way of
synthesising a cmd-drag. On macOS 27.0 none of the drag strategies move an item, which
is why nothing here tries to rearrange your icons for you.

## Notes from macOS 27

Things measured here that cost real time, in case they save someone else's:

- **Status items aren't windows.** `CGWindowListCopyWindowInfo` returns nothing at the
  status window level; the bar is composited in the Window Server. Accessibility
  (`AXExtrasMenuBar`) is the only way to read it, and it needs the permission just to
  look.
- **You cannot move another app's icon.** Every route for synthesising a cmd-drag was
  tried — HID and session taps, `postToPid` at ControlCenter, MenuBarAgent and
  SystemUIServer, faithful drags, teleports, warping the real cursor, Command as flags
  versus a real key press. None reorder an item, though doing it by hand still works.
- **`NSMenuItem.image` isn't drawn.** Not an app icon, not an SF Symbol, not on
  enabled items. That is why the app picker here is a sheet with a table rather than
  the pop-up menu it started as — a table draws the same images without complaint.
- **An `autosaveName` resets an item's position.** Setting one gives the item a new
  identity, so macOS forgets the slot it had and places it as new, at the far left.
  A preferred position (`NSStatusItem Preferred Position <name>`, larger is further
  left) *is* honoured for your own item, but only when the item is created — moving
  one later means removing and recreating it.
- **An allowlist entry is only honoured for an app in an Applications folder.** The
  same ad-hoc signed bundle run from `/private/tmp` had its icon concealed by every
  assertion whether it was on the list or not; copied to `/Applications` it was left
  alone. Signing is not what decides it, which is probably where the belief that
  assessment mode needs Developer ID comes from.

## Layout

```
Sources/
  AssertionController.swift   the app: chevron, conceal/reveal, auto-hide
  AssessmentMode.swift        the macOS 27 concealment assertion
  PreferencesWindow.swift     settings, built in code
  AppPicker.swift             the "add an app" sheet (a table, because menus can't
                              draw icons on 27)
  AccessibilityAccess.swift   asking for, and re-checking, the one permission
  Settings.swift              what the user can change
  GlobalHotkey.swift          keyboard shortcut (Carbon, needs no permission)
  MenuBarApps.swift           which apps own menu bar icons
  AXMenuBarItems.swift        reading the bar through Accessibility
  LaunchAtLogin.swift         SMAppService
  JustHide.swift              glyphs
  Log.swift                   public os_log
  WidthController.swift       the --width fallback mechanism
  CollapseCalibrator.swift    measuring what the fallback may claim
  MenuBarGeometry.swift       display geometry for the fallback
  SpacerPlacement.swift       spacer placement for the fallback
  ItemMover.swift             synthetic cmd-drag (diagnostics only; see below)
  MenuBarItems.swift          the old window-list route, kept as evidence
tools/make-icon.swift         draws the app icon
build.sh                      compiles and assembles the bundle
```

No Xcode project: one target, a handful of files, and a shell script is less to keep
in sync than a `pbxproj`.

## Releasing

`./release.sh` builds, signs, notarises, staples, zips and checksums a release;
`--publish` also creates the GitHub release and bumps the cask in
[benjustjammin/homebrew-tap](https://github.com/benjustjammin/homebrew-tap). Tagging
`v*` does the same thing on CI. The version comes from `CFBundleShortVersionString`,
so the tag, the zip and the cask cannot drift apart.

[docs/RELEASING.md](docs/RELEASING.md) covers the one-off setup: creating a Developer
ID certificate without Xcode, storing notarisation credentials, and which secrets CI
needs.

## Credit

The assessment-mode approach was found via
[jordanbaird/Ice#995](https://github.com/jordanbaird/Ice/pull/995), which adapted it
from [Thaw](https://github.com/thaw-app/Thaw)'s `PlatformRuntimeKit` by way of
[Barometer](https://github.com/mackid1993/Barometer). Both are GPLv3. The
implementation here is independent, but the idea is theirs and they deserve the
credit — if you want a full-featured menu bar manager rather than this, go and use
Thaw.

Descended in spirit from [Hidden Bar](https://github.com/dwarvesf/hidden) (MIT), which
is what I wanted to keep using.

## Licence

[GPLv3](LICENSE). The code here is written from scratch, so a permissive licence would
probably have been defensible — but the mechanism that makes it work was learned from
Ice and Thaw, both GPLv3, and matching them removes any argument about it. If you build
on this, your users get the same freedoms.
