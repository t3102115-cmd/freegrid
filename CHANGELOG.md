# Changelog

## 1.0.0
* Settings page gets an **Enabled** switch, an icon and an About note.
* Free mode: positions follow a folder through renames; a new folder appears where the icon it replaced was;
  a new app gets the first free spot instead of landing on top of another icon.
* Free mode ignores saved positions for a page that no longer matches (e.g. after iOS "Reset Home Screen Layout").
* Crash-loop guard only trips when a real SpringBoard crash report exists (quick manual resprings are fine).
* Reinstalling clears an automatic crash-loop disable. Log file is size-limited.
* Package depends on iOS 9.x (`firmware`), has postinst/postrm scripts.

## 0.1.0
* Grid and Free modes, PreferenceLoader settings (Mode, Reset layout), mode conversion, kill switch.

## 0.0.x
* Prototype: gap placeholders, persistence, drag handling fixes.
