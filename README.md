# FreeGrid

A SpringBoard tweak for **iOS 9.3.x, armv7** (tested: iPhone 4S, 9.3.6, Phoenix jailbreak) that lets you
put home screen icons anywhere, like the modern iOS home screen.

Two modes, switchable in **Settings > FreeGrid**:

| Mode | Behaviour |
|------|-----------|
| **Grid aligned** | Drag any icon to *any* grid slot and leave empty gaps. Icons stay where you drop them; they don't snap back to the top-left or fill the gaps. |
| **Free (anywhere)** | Icons go exactly where you drop them, no grid: overlap, circles, whatever. Dropping an icon on the *centre* of another icon still creates a folder. |

Folders and the dock behave like stock. Layout survives respring, reboot and re-jailbreak.
**Reset layout** (Settings > FreeGrid) restores the stock layout.

Install the prebuilt package: `packages/com.example.freegrid_0.1.0_iphoneos-arm.deb` (needs MobileSubstrate and PreferenceLoader).

## How it works

* **Grid mode.** Each root-folder page (`SBIconListModel`) is kept *dense*: entries map 1:1 to grid slots, and empty
  slots before the last icon hold invisible `SBPlaceholderIcon` objects ("gaps"). Removing an icon leaves a gap,
  inserting onto a gap swaps it in, inserting onto an icon pushes only up to the next gap, trailing gaps are
  trimmed. A gap is never saved to `IconState.plist` (the archiver skips it), so that file stays a normal dense list.
* **Free mode.** The model is stock. Every icon has its own saved view origin; `-[SBIconListView originForIconAtIndex:]`
  and `centerForIcon:` return it instead of the grid slot. Drag/drop records where the dragged icon's view is.
* **Persistence.** `/var/mobile/Library/Preferences/com.example.freegrid.plist` stores per page the icon keys and gap
  slots (grid) or per-icon positions (free). It is re-applied right after SpringBoard unarchives `IconState.plist`;
  a page whose icons changed since (e.g. app installed while the tweak was off) simply stays stock.
* **Mode switch / reset** are done from live state, only our own plist is rewritten, then SpringBoard is relaunched.
* Settings are a plain PreferenceLoader plist (no code), domain `com.example.freegrid.settings`.

## Safety

* **Kill switch:** create `/var/mobile/.freegrid_disable` (e.g. `ssh iphone-mobile 'touch /var/mobile/.freegrid_disable'`)
  and respring: the tweak does nothing at all. Delete the file to re-enable.
* **Crash-loop guard:** three SpringBoard launches in a row that don't survive 30 s create that file automatically.
* All hook logic is wrapped in `@try/@catch` and falls back to stock behaviour; errors go to
  `/var/mobile/Library/Logs/freegrid.log`. `touch /var/mobile/.freegrid_debug` + respring turns on verbose tracing.
* `IconState.plist` is only ever written by SpringBoard itself.
* MobileSubstrate Safe Mode (hold volume-up while SpringBoard starts) also disables the tweak.

## Known limits

* Max 16 icons per page in both modes (stock page capacity).
* Free mode: a *new folder* created by dropping on an icon takes that slot's grid position, not the icon's free position;
  newly installed apps appear at their grid slot.
* Free mode never wraps/aligns; switching back to Grid snaps each icon to the nearest free slot (reading order).
* iPhone portrait only (iPhone 4S home screen doesn't rotate).

## Build on Fedora

```bash
sudo dnf install dpkg fakeroot perl-core git curl xz   # one time
tools/setup-fedora.sh                                  # Theos + armv7 toolchain + iOS 9.3 SDK (+ SDK stub fix)
export THEOS=~/theos
make package FINALPACKAGE=1                            # -> packages/com.example.freegrid_<version>_iphoneos-arm.deb
```

Notes:
* `fakeroot` is used by `dm.pl`; if you build inside a sandbox that blocks localhost sockets the package comes out empty.
* The Makefile uses gzip for the .deb (old Cydia dpkg reads it reliably).
* Target: `iphone:clang:9.3:9.0`, `ARCHS = armv7`.

## Install on the phone

The phone's SSH only offers legacy algorithms. Add to `~/.ssh/config`:

```
Host iphone
    HostName <phone-ip>
    User root
    IdentityFile ~/.ssh/iphone_rsa
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    KexAlgorithms +diffie-hellman-group14-sha1
```

(on Fedora 40+ you may need `sudo update-crypto-policies --set DEFAULT:SHA1`), then:

```bash
ssh-keygen -t rsa -b 3072 -f ~/.ssh/iphone_rsa -N ""    # and ssh-copy-id -i ~/.ssh/iphone_rsa.pub iphone
scp packages/com.example.freegrid_0.1.0_iphoneos-arm.deb iphone:/var/root/
ssh iphone 'dpkg -i /var/root/com.example.freegrid_0.1.0_iphoneos-arm.deb && killall -9 SpringBoard'
```

Before the first test, back up `/var/mobile/Library/SpringBoard/IconState.plist` (a copy of the one used during
development is in `backup/`).

## Debugging

```bash
ssh iphone 'tail -f /var/mobile/Library/Logs/freegrid.log'
ssh iphone 'ls -t /var/mobile/Library/Logs/CrashReporter | head'   # SpringBoard-*.ips
```

To symbolicate a crash, dump the ObjC metadata with the toolchain's `otool -ov SpringBoard` (binary pulled from
`/System/Library/CoreServices/SpringBoard.app/SpringBoard`) and run `research/otool2h.py` on it. The iOS 9.3.6 class
interfaces we relied on are in `research/headers-9.3.6/`.
