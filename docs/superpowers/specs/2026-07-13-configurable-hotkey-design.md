# Configurable global hotkey — design

## Problem

Work Log's clipboard-capture hotkey is hardcoded to Ctrl+Alt+L: detected via
`GetAsyncKeyState` polling in `checkGlobalHotkey()` (`src/main.zig`), with the
combo also baked into `simulateCtrlC()`'s key-release logic and various
labels/messages. Users should be able to pick a different combo from the
Settings dialog, with Ctrl+Alt+L remaining the default.

## Storage

Two new package-level vars alongside the existing settings globals:

- `hotkey_mods: u8` — bitmask, `Ctrl=1, Alt=2, Shift=4, Win=8`. Default `3`
  (Ctrl+Alt).
- `hotkey_key: u8` — ASCII code of the non-modifier key, restricted to
  `A`–`Z` / `0`–`9`. Default `'L'` (0x4C).

Persisted as two new lines in `settings.txt` (`hotkey_mods=<n>`,
`hotkey_key=<n>`), read/written in `loadSettings`/`saveSettings` the same way
as `work_start_hour` etc.

## Detection & simulation

`checkGlobalHotkey()` currently hardcodes VK 0x11 (Ctrl), 0x12 (Alt), 0x4C
(L). It generalizes to: for each bit set in `hotkey_mods`, check the
corresponding VK via `GetAsyncKeyState` (Ctrl=0x11, Alt=0x12, Shift=0x10,
Win=0x5B/0x5C — treat either Win key as a match); AND with `GetAsyncKeyState`
on `hotkey_key` directly (ASCII code doubles as the VK code for A–Z/0–9).
Same "pressed && !hotkey_was_down" edge-triggering as today.

`simulateCtrlC()`'s first step releases whichever keys are configured
(iterate the same bitmask + `hotkey_key`) instead of the hardcoded Alt+L
release. The subsequent Ctrl+C simulation is unchanged — it copies the
current selection and has nothing to do with which combo triggered it.

## Settings UI

New "Global Shortcut" row in the Settings modal (`#settings-overlay`):

- A read-only field showing the *live* current combo (e.g. "Ctrl+Alt+L"),
  formatted from `hotkey_mods`/`hotkey_key` when `app.get-settings` populates
  the form.
- A "Record" button. Clicking arms a listening state; the next qualifying
  keydown is captured and shown as a preview (not yet saved).
- A "Reset to default" link that sets the pending value back to Ctrl+Alt+L.
- Esc cancels an in-progress recording without changing the field.

Recording rules (client-side, JS `keydown` handler):

- Ignore pure-modifier keydowns; wait for a non-modifier key.
- Reject the combo (flash an inline error, keep listening) unless the key is
  A–Z or 0–9 and at least one of Ctrl/Alt/Shift/Win is held. This prevents
  configuring a bare letter as a system-wide hotkey.
- On a qualifying keydown, compute the mods bitmask from
  `ctrlKey`/`altKey`/`shiftKey`/`metaKey` and the key char from `e.key`
  (uppercased), update the preview, exit recording.

`saveSettingsForm()` includes `hotkey_mods` (number) and `hotkey_key`
(single-char string) in the `app.save-settings` payload alongside the
existing fields.

`saveSettingsHandler` applies the same validation server-side (mods != 0,
key in A–Z/0–9) before assigning `hotkey_mods`/`hotkey_key`, ignoring the
update otherwise — consistent with how existing fields (e.g.
`work_start_hour <= 23`) are validated.

`getSettingsHandler`'s JSON response gains `hotkey_mods` and `hotkey_key`
fields so the modal can render the live value when opened.

## Everywhere else (deliberately left static)

Tray tooltip, tray menu item label, the About-modal instructions, and the
default status-bar message keep their current hardcoded wording, reworded
only to stop asserting the combo is fixed — e.g. "Work Log — your shortcut
(default Ctrl+Alt+L)" instead of "Work Log - Ctrl+Alt+L to store". No dynamic
rebuild plumbing (runtime-built tray arrays, HTML regeneration on settings
change) is introduced; the Settings modal's live field is the only place the
actual configured value is shown.

`README.md` gets the equivalent wording tweak: describe Ctrl+Alt+L as the
default, configurable from Settings, rather than as the fixed shortcut.

`app.zon`'s static `.shortcuts`/`.menus` accelerator declarations are left
unchanged. They're compile-time manifest metadata, not the functional
trigger (confirmed by code search — the real detection is the
`GetAsyncKeyState` polling above), so they can't reflect a runtime setting
without a rebuild. This is a known, accepted limitation.

## Validation & edge cases

- Reject function keys, Escape, Tab, Enter, Space, arrows, etc. during
  recording — scope is limited to A–Z/0–9, matching today's single-letter
  design.
- Reject a combo with no modifiers, both client- and server-side.
- Invalid/missing fields in the save payload leave the current in-memory
  value untouched (same pattern as existing settings fields).

## Testing

- Manual: change the shortcut in Settings, confirm the old combo no longer
  triggers capture and the new one does; confirm it persists across an app
  restart (reads back from `settings.txt`).
- Unit tests in `src/tests.zig`: extend settings load/save parsing coverage
  with cases for `hotkey_mods`/`hotkey_key`.
