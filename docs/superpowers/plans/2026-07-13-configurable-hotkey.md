# Configurable Global Hotkey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user replace the hardcoded Ctrl+Alt+L clipboard-capture hotkey with a combo of their choosing from the Settings dialog, defaulting to Ctrl+Alt+L.

**Architecture:** Two new package-level globals (`hotkey_mods: u8` bitmask, `hotkey_key: u8` ASCII code) drive the existing `GetAsyncKeyState`-polling detection and the key-release step of the clipboard-copy simulation, generalized from their current hardcoded Ctrl/Alt/L checks. The combo is persisted in the existing `settings.txt` key=value file and exposed over the existing `app.get-settings`/`app.save-settings` bridge commands. The Settings modal gains a press-to-record field that is the only place the live value is shown; all other UI/README text is reworded to describe Ctrl+Alt+L as a changeable default rather than dynamically regenerated.

**Tech Stack:** Zig 0.16 (native app logic), inline HTML/CSS/JS generated from `src/main.zig` (WebView UI), Win32 (`GetAsyncKeyState`/`keybd_event`) for key polling and clipboard simulation.

## Global Constraints

- Modifier bitmask: `Ctrl=1, Alt=2, Shift=4, Win=8` (from spec).
- Default combo: `hotkey_mods=3` (Ctrl+Alt), `hotkey_key='L'` (0x4C) — must match today's behavior exactly.
- Non-modifier key restricted to `A`–`Z` / `0`–`9` only (spec: "matching today's single-letter design").
- A combo must have at least one modifier bit set; reject combos with zero modifiers, both client- and server-side.
- No dynamic rebuild of tray/About/status text — only the Settings modal's record field shows the live value (spec: "deliberately left static").
- `app.zon`'s `.shortcuts`/`.menus` declarations are left unchanged (known limitation, not the functional trigger).

---

### Task 1: Hotkey storage globals + pure validation/matching helpers

**Files:**
- Modify: `src/main.zig:14-25` (constants and settings globals), `src/main.zig:727-741` (`checkGlobalHotkey`, for context only — not changed in this task)
- Test: `src/main.zig` (inline `test { }` blocks — see note below)

**Note on test location:** `src/tests.zig` exists but is **not** wired into the build — `zig build test`'s root module comes from `appModule()` (built from `app.zon`'s entry point, `src/main.zig`), which never imports `tests.zig`. The 7 tests actually run by `native test` today are the inline `test "..."` blocks at the bottom of `src/main.zig` (lines 2088-2159). Do not add tests to `tests.zig` — they would silently never run. Add new tests as inline blocks in `src/main.zig`, next to the existing ones, following their exact style (bare function calls, no `main.` prefix, `std.testing.expect` used directly since `std` is already imported at the top of the file).

**Interfaces:**
- Produces: `const hotkey_mod_ctrl: u8 = 1`, `const hotkey_mod_alt: u8 = 2`, `const hotkey_mod_shift: u8 = 4`, `const hotkey_mod_win: u8 = 8`; `var hotkey_mods: u8` (default `hotkey_mod_ctrl | hotkey_mod_alt`), `var hotkey_key: u8` (default `'L'`); `fn isValidHotkeyMods(mods: u8) bool`; `fn isValidHotkeyKey(key: u8) bool`; `fn hotkeyMatches(mods: u8, ctrl: bool, alt: bool, shift: bool, win: bool, key_down: bool) bool`.
- Consumes: nothing (first task).

- [ ] **Step 1: Write the failing tests**

Append to the end of `src/main.zig` (after the existing `test "analytics body renders without entries"` block at line 2159):

```zig
test "isValidHotkeyMods accepts any non-empty subset of the 4 modifier bits" {
    try std.testing.expect(isValidHotkeyMods(1));
    try std.testing.expect(isValidHotkeyMods(3));
    try std.testing.expect(isValidHotkeyMods(15));
    try std.testing.expect(!isValidHotkeyMods(0));
    try std.testing.expect(!isValidHotkeyMods(16));
}

test "isValidHotkeyKey accepts only A-Z and 0-9" {
    try std.testing.expect(isValidHotkeyKey('L'));
    try std.testing.expect(isValidHotkeyKey('A'));
    try std.testing.expect(isValidHotkeyKey('9'));
    try std.testing.expect(!isValidHotkeyKey('a'));
    try std.testing.expect(!isValidHotkeyKey(' '));
    try std.testing.expect(!isValidHotkeyKey(27)); // Escape
}

test "hotkeyMatches requires exactly the configured modifiers and key to be down" {
    const mods = hotkey_mod_ctrl | hotkey_mod_alt;
    // Ctrl+Alt+L combo, all three down -> matches
    try std.testing.expect(hotkeyMatches(mods, true, true, false, false, true));
    // key not down -> no match
    try std.testing.expect(!hotkeyMatches(mods, true, true, false, false, false));
    // a required modifier not down -> no match
    try std.testing.expect(!hotkeyMatches(mods, true, false, false, false, true));
    // extra modifier incidentally held is ignored (matches today's ctrl+alt+l-only check)
    try std.testing.expect(hotkeyMatches(mods, true, true, true, false, true));
}

test "hotkeyMatches with a single-modifier combo" {
    const mods = hotkey_mod_shift;
    try std.testing.expect(hotkeyMatches(mods, false, false, true, false, true));
    try std.testing.expect(!hotkeyMatches(mods, false, false, false, false, true));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `native test`
Expected: build fails — `error: use of undeclared identifier 'isValidHotkeyMods'` (or similar undefined-identifier errors for `isValidHotkeyKey`, `hotkeyMatches`, `hotkey_mod_ctrl`, etc.)

- [ ] **Step 3: Add the constants, globals, and pure helper functions**

In `src/main.zig`, replace lines 14-25:

```zig
const hotkey_timer_id: u64 = 42;
const hotkey_interval_ns: u64 = 150_000_000;
const clipboard_read_timer_id: u64 = 43;
const clipboard_read_delay_ns: u64 = 200_000_000;

const Theme = enum { auto, light, dark };

var work_start_hour: u8 = 9;
var work_end_hour: u8 = 17;
var app_theme: Theme = .auto;
var fill_gaps: bool = false;
var show_weekends: bool = false;
```

with:

```zig
const hotkey_timer_id: u64 = 42;
const hotkey_interval_ns: u64 = 150_000_000;
const clipboard_read_timer_id: u64 = 43;
const clipboard_read_delay_ns: u64 = 200_000_000;

const hotkey_mod_ctrl: u8 = 1;
const hotkey_mod_alt: u8 = 2;
const hotkey_mod_shift: u8 = 4;
const hotkey_mod_win: u8 = 8;

const Theme = enum { auto, light, dark };

var work_start_hour: u8 = 9;
var work_end_hour: u8 = 17;
var app_theme: Theme = .auto;
var fill_gaps: bool = false;
var show_weekends: bool = false;
var hotkey_mods: u8 = hotkey_mod_ctrl | hotkey_mod_alt;
var hotkey_key: u8 = 'L';

/// A combo needs at least one modifier so the key alone never fires as a
/// system-wide hotkey while typing normally.
fn isValidHotkeyMods(mods: u8) bool {
    return mods >= 1 and mods <= 15;
}

fn isValidHotkeyKey(key: u8) bool {
    return (key >= 'A' and key <= 'Z') or (key >= '0' and key <= '9');
}

/// Pure combination check shared by the live poller and its tests: every
/// modifier bit set in `mods` must be currently held, and `key_down` must be
/// true. Modifiers not in `mods` are ignored even if incidentally held,
/// matching today's exact ctrl+alt+l-only check.
fn hotkeyMatches(mods: u8, ctrl: bool, alt: bool, shift: bool, win: bool, key_down: bool) bool {
    if (!key_down) return false;
    if ((mods & hotkey_mod_ctrl) != 0 and !ctrl) return false;
    if ((mods & hotkey_mod_alt) != 0 and !alt) return false;
    if ((mods & hotkey_mod_shift) != 0 and !shift) return false;
    if ((mods & hotkey_mod_win) != 0 and !win) return false;
    return true;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `native test`
Expected: `Build Summary: 7/7 steps succeeded; 11/11 tests passed` (the 4 new tests added to the previous 7)

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "Add configurable hotkey storage and pure validation/matching helpers"
```

---

### Task 2: Generalize hotkey detection and clipboard-copy key release

**Files:**
- Modify: `src/main.zig:727-753` (`checkGlobalHotkey`, `simulateCtrlC`)

**Interfaces:**
- Consumes: `hotkey_mods: u8`, `hotkey_key: u8`, `hotkeyMatches(mods, ctrl, alt, shift, win, key_down) bool` (Task 1).
- Produces: same function names/signatures (`checkGlobalHotkey() bool`, `simulateCtrlC() void`), now driven by the configurable combo instead of hardcoded Ctrl/Alt/L.

- [ ] **Step 1: Replace `checkGlobalHotkey`**

Replace `src/main.zig:727-741`:

```zig
fn checkGlobalHotkey() bool {
    if (builtin.os.tag != .windows) return false;
    const ctrl = w32.GetAsyncKeyState(0x11) < 0;
    const alt = w32.GetAsyncKeyState(0x12) < 0;
    const l_key = w32.GetAsyncKeyState(0x4C) < 0;

    const pressed = ctrl and alt and l_key;
    if (pressed and !hotkey_was_down) {
        hotkey_was_down = true;
        debugLog("HOTKEY DETECTED: Ctrl+Alt+L pressed!");
        return true;
    }
    if (!pressed) hotkey_was_down = false;
    return false;
}
```

with:

```zig
fn checkGlobalHotkey() bool {
    if (builtin.os.tag != .windows) return false;
    const ctrl = w32.GetAsyncKeyState(0x11) < 0;
    const alt = w32.GetAsyncKeyState(0x12) < 0;
    const shift = w32.GetAsyncKeyState(0x10) < 0;
    const win = w32.GetAsyncKeyState(0x5B) < 0 or w32.GetAsyncKeyState(0x5C) < 0;
    const key_down = w32.GetAsyncKeyState(@intCast(hotkey_key)) < 0;

    const pressed = hotkeyMatches(hotkey_mods, ctrl, alt, shift, win, key_down);
    if (pressed and !hotkey_was_down) {
        hotkey_was_down = true;
        debugLog("HOTKEY DETECTED: configured combo pressed!");
        return true;
    }
    if (!pressed) hotkey_was_down = false;
    return false;
}
```

- [ ] **Step 2: Replace `simulateCtrlC`'s release step**

Replace `src/main.zig:743-753`:

```zig
fn simulateCtrlC() void {
    if (builtin.os.tag != .windows) return;
    debugLog("simulateCtrlC: releasing Alt+L, then sending Ctrl+C");
    w32.keybd_event(0x12, 0, w32.KEYEVENTF_KEYUP, 0); // release Alt
    w32.keybd_event(0x4C, 0, w32.KEYEVENTF_KEYUP, 0); // release L
    w32.Sleep(30);
    w32.keybd_event(0x11, 0, 0, 0); // Ctrl down
    w32.keybd_event(0x43, 0, 0, 0); // C down
    w32.keybd_event(0x43, 0, w32.KEYEVENTF_KEYUP, 0); // C up
    w32.keybd_event(0x11, 0, w32.KEYEVENTF_KEYUP, 0); // Ctrl up
}
```

with:

```zig
fn simulateCtrlC() void {
    if (builtin.os.tag != .windows) return;
    debugLog("simulateCtrlC: releasing configured combo, then sending Ctrl+C");
    // Release every modifier/key that's part of the configured combo so it
    // doesn't interfere with the synthetic Ctrl+C below. Ctrl itself is left
    // alone here regardless of whether it's part of the combo - the
    // subsequent Ctrl+C block presses and releases it either way.
    if (hotkey_mods & hotkey_mod_win != 0) {
        w32.keybd_event(0x5B, 0, w32.KEYEVENTF_KEYUP, 0);
        w32.keybd_event(0x5C, 0, w32.KEYEVENTF_KEYUP, 0);
    }
    if (hotkey_mods & hotkey_mod_shift != 0) w32.keybd_event(0x10, 0, w32.KEYEVENTF_KEYUP, 0);
    if (hotkey_mods & hotkey_mod_alt != 0) w32.keybd_event(0x12, 0, w32.KEYEVENTF_KEYUP, 0);
    w32.keybd_event(hotkey_key, 0, w32.KEYEVENTF_KEYUP, 0);
    w32.Sleep(30);
    w32.keybd_event(0x11, 0, 0, 0); // Ctrl down
    w32.keybd_event(0x43, 0, 0, 0); // C down
    w32.keybd_event(0x43, 0, w32.KEYEVENTF_KEYUP, 0); // C up
    w32.keybd_event(0x11, 0, w32.KEYEVENTF_KEYUP, 0); // Ctrl up
}
```

- [ ] **Step 3: Build and run the existing test suite to confirm no regressions**

Run: `native test`
Expected: `Build Summary: 7/7 steps succeeded; 11/11 tests passed` (unchanged from Task 1 — this task has no new unit tests since it wraps live Win32 key state, but the pure logic it delegates to is already covered)

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "Generalize hotkey detection and clipboard-copy key release to the configured combo"
```

---

### Task 3: Persist and expose the hotkey combo via settings load/save and the bridge

**Files:**
- Modify: `src/main.zig:206-248` (`getSettingsHandler`, `saveSettingsHandler`), `src/main.zig:536-612` (`loadSettings`, `saveSettings`)

**Interfaces:**
- Consumes: `hotkey_mods`, `hotkey_key`, `isValidHotkeyMods`, `isValidHotkeyKey` (Task 1).
- Produces: `app.get-settings` JSON response gains `"hotkey_mods":<0-15>,"hotkey_key":<65-90 or 48-57>` fields; `app.save-settings` accepts the same two numeric fields in its payload; `settings.txt` gains `hotkey_mods=<n>` and `hotkey_key=<n>` lines.

- [ ] **Step 1: Extend `getSettingsHandler`**

Replace `src/main.zig:206-220`:

```zig
    fn getSettingsHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        _ = context;
        const theme_str = switch (app_theme) {
            .auto => "auto",
            .light => "light",
            .dark => "dark",
        };
        return std.fmt.bufPrint(output, "{{\"work_start_hour\":{d},\"work_end_hour\":{d},\"theme\":\"{s}\",\"fill_gaps\":{s}}}", .{
            work_start_hour,
            work_end_hour,
            theme_str,
            @as([]const u8, if (fill_gaps) "true" else "false"),
        }) catch "{}";
    }
```

with:

```zig
    fn getSettingsHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        _ = context;
        const theme_str = switch (app_theme) {
            .auto => "auto",
            .light => "light",
            .dark => "dark",
        };
        return std.fmt.bufPrint(output, "{{\"work_start_hour\":{d},\"work_end_hour\":{d},\"theme\":\"{s}\",\"fill_gaps\":{s},\"hotkey_mods\":{d},\"hotkey_key\":{d}}}", .{
            work_start_hour,
            work_end_hour,
            theme_str,
            @as([]const u8, if (fill_gaps) "true" else "false"),
            hotkey_mods,
            hotkey_key,
        }) catch "{}";
    }
```

- [ ] **Step 2: Extend `saveSettingsHandler`**

In `src/main.zig:222-248`, insert after the `fill_gaps` block (after line 244, `        }` closing `if (jsonBoolField(payload, "fill_gaps")) |v| {`) and before `self.saveSettings();`:

```zig
        if (jsonUnsignedField(payload, "hotkey_mods")) |v| {
            if (isValidHotkeyMods(v)) hotkey_mods = v;
        }
        if (jsonUnsignedField(payload, "hotkey_key")) |v| {
            if (isValidHotkeyKey(v)) hotkey_key = v;
        }
```

So the full handler body reads (for reference, no other lines change):

```zig
    fn saveSettingsHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const payload = invocation.request.payload;

        if (jsonUnsignedField(payload, "work_start_hour")) |v| {
            if (v <= 23) work_start_hour = v;
        }
        if (jsonUnsignedField(payload, "work_end_hour")) |v| {
            if (v <= 23) work_end_hour = v;
        }
        var theme_buf: [16]u8 = undefined;
        if (jsonStringField(payload, "theme", &theme_buf)) |theme_val| {
            if (std.mem.eql(u8, theme_val, "light")) {
                app_theme = .light;
            } else if (std.mem.eql(u8, theme_val, "dark")) {
                app_theme = .dark;
            } else {
                app_theme = .auto;
            }
        }
        if (jsonBoolField(payload, "fill_gaps")) |v| {
            fill_gaps = v;
        }
        if (jsonUnsignedField(payload, "hotkey_mods")) |v| {
            if (isValidHotkeyMods(v)) hotkey_mods = v;
        }
        if (jsonUnsignedField(payload, "hotkey_key")) |v| {
            if (isValidHotkeyKey(v)) hotkey_key = v;
        }

        self.saveSettings();
        return self.renderCurrentViewJson(output);
    }
```

- [ ] **Step 3: Extend `loadSettings`' parsing chain**

In `src/main.zig:536-582`, replace the final `else if` branch and closing braces (lines 578-581):

```zig
            } else if (std.mem.eql(u8, key, "show_weekends")) {
                show_weekends = std.mem.eql(u8, value, "1");
            }
        }
    }
```

with:

```zig
            } else if (std.mem.eql(u8, key, "show_weekends")) {
                show_weekends = std.mem.eql(u8, value, "1");
            } else if (std.mem.eql(u8, key, "hotkey_mods")) {
                const v = std.fmt.parseUnsigned(u8, value, 10) catch hotkey_mods;
                if (isValidHotkeyMods(v)) hotkey_mods = v;
            } else if (std.mem.eql(u8, key, "hotkey_key")) {
                const v = std.fmt.parseUnsigned(u8, value, 10) catch hotkey_key;
                if (isValidHotkeyKey(v)) hotkey_key = v;
            }
        }
    }
```

- [ ] **Step 4: Extend `saveSettings`' written content**

Replace `src/main.zig:602-609`:

```zig
        var write_buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&write_buf, "work_start_hour={d}\nwork_end_hour={d}\ntheme={s}\nfill_gaps={d}\nshow_weekends={d}\n", .{
            work_start_hour,
            work_end_hour,
            theme_str,
            @as(u8, if (fill_gaps) 1 else 0),
            @as(u8, if (show_weekends) 1 else 0),
        }) catch return;
```

with:

```zig
        var write_buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&write_buf, "work_start_hour={d}\nwork_end_hour={d}\ntheme={s}\nfill_gaps={d}\nshow_weekends={d}\nhotkey_mods={d}\nhotkey_key={d}\n", .{
            work_start_hour,
            work_end_hour,
            theme_str,
            @as(u8, if (fill_gaps) 1 else 0),
            @as(u8, if (show_weekends) 1 else 0),
            hotkey_mods,
            hotkey_key,
        }) catch return;
```

- [ ] **Step 5: Build and run the test suite**

Run: `native test`
Expected: `Build Summary: 7/7 steps succeeded; 11/11 tests passed` (no new unit tests here — this task is Windows file-I/O-bound persistence code, consistent with the existing settings fields, none of which have dedicated persistence tests either; correctness is checked manually in Task 6)

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "Persist and expose the hotkey combo through settings load/save and the bridge"
```

---

### Task 4: Add the "Global shortcut" press-to-record field to the Settings modal

**Files:**
- Modify: `src/main.zig:1266-1270` (modal CSS), `src/main.zig:1336-1354` (settings modal HTML), `src/main.zig:1406-1409` (JS state init), `src/main.zig:1483-1519` (`openSettings`/`saveSettingsForm`)

**Interfaces:**
- Consumes: `hotkey_mods`/`hotkey_key` fields from `app.get-settings` response; `app.save-settings` payload accepting `hotkey_mods`/`hotkey_key` numbers (Task 3).
- Produces: JS globals `pendingHotkeyMods`, `pendingHotkeyKey`; JS functions `hotkeyLabel(mods, key)`, `recordHotkey()`, `resetHotkey()`, consumed only within this settings modal.

- [ ] **Step 1: Add CSS for the shortcut field**

In `src/main.zig`, after line 1270 (`\\.modal-actions button.primary{background:#3b82f6;color:#fff;border-color:#3b82f6}`), insert:

```zig
        \\.hotkey-field{display:flex;align-items:center;gap:6px}
        \\.hotkey-field span{font-family:monospace;font-size:13px;padding:2px 8px;background:#f3f4f6;border-radius:4px;min-width:90px;text-align:center;display:inline-block}
        \\.hotkey-field button{font-size:12px;padding:4px 10px;border:1px solid #d1d5db;border-radius:6px;cursor:pointer;background:#fff;color:#374151}
        \\.hotkey-hint{font-size:12px;color:#6b7280;margin:-4px 0 12px 0}
        \\.hotkey-hint.error{color:#dc2626}
```

And after line 1292 (`\\:root[data-theme="dark"] .modal-panel input,:root[data-theme="dark"] .modal-panel select{background:#0f1117;color:#e5e7eb;border-color:#2d3140}`), insert:

```zig
        \\:root[data-theme="dark"] .hotkey-field span{background:#0f1117;color:#e5e7eb}
        \\:root[data-theme="dark"] .hotkey-field button{background:#0f1117;color:#e5e7eb;border-color:#2d3140}
```

- [ ] **Step 2: Add the modal row**

Replace `src/main.zig:1347-1348`:

```zig
        \\<div class="modal-row"><label for="set-fillgaps">Fill gaps in analytics</label><input type="checkbox" id="set-fillgaps"></div>
        \\<div class="modal-row"><label>Backup</label><button onclick="exportData()">Export CSV&hellip;</button></div>
```

with:

```zig
        \\<div class="modal-row"><label for="set-fillgaps">Fill gaps in analytics</label><input type="checkbox" id="set-fillgaps"></div>
        \\<div class="modal-row"><label>Global shortcut</label><div class="hotkey-field"><span id="set-hotkey-display">Ctrl+Alt+L</span><button type="button" onclick="recordHotkey()">Record</button><button type="button" onclick="resetHotkey()">Reset</button></div></div>
        \\<div class="hotkey-hint" id="hotkey-hint">Default: Ctrl+Alt+L</div>
        \\<div class="modal-row"><label>Backup</label><button onclick="exportData()">Export CSV&hellip;</button></div>
```

- [ ] **Step 3: Add JS state and the `hotkeyLabel` formatter**

Replace `src/main.zig:1406-1408`:

```zig
    pos = appendStr(buf, pos, "let weekendsShown = ");
    pos = appendStr(buf, pos, if (show_weekends) "true" else "false");
    pos = appendStr(buf, pos, ";\n");
```

with:

```zig
    pos = appendStr(buf, pos, "let weekendsShown = ");
    pos = appendStr(buf, pos, if (show_weekends) "true" else "false");
    pos = appendStr(buf, pos, ";\n");
    pos = appendStr(buf, pos,
        \\const HOTKEY_MOD_CTRL=1,HOTKEY_MOD_ALT=2,HOTKEY_MOD_SHIFT=4,HOTKEY_MOD_WIN=8;
        \\let pendingHotkeyMods=HOTKEY_MOD_CTRL|HOTKEY_MOD_ALT, pendingHotkeyKey=76;
        \\function hotkeyLabel(mods,key){
        \\  const parts=[];
        \\  if(mods&HOTKEY_MOD_CTRL)parts.push("Ctrl");
        \\  if(mods&HOTKEY_MOD_ALT)parts.push("Alt");
        \\  if(mods&HOTKEY_MOD_SHIFT)parts.push("Shift");
        \\  if(mods&HOTKEY_MOD_WIN)parts.push("Win");
        \\  parts.push(String.fromCharCode(key));
        \\  return parts.join("+");
        \\}
        \\function resetHotkey(){
        \\  pendingHotkeyMods=HOTKEY_MOD_CTRL|HOTKEY_MOD_ALT;
        \\  pendingHotkeyKey=76;
        \\  document.getElementById("set-hotkey-display").textContent=hotkeyLabel(pendingHotkeyMods,pendingHotkeyKey);
        \\  const hint=document.getElementById("hotkey-hint");
        \\  hint.textContent="Default: Ctrl+Alt+L";
        \\  hint.classList.remove("error");
        \\}
        \\function recordHotkey(){
        \\  const disp=document.getElementById("set-hotkey-display");
        \\  const hint=document.getElementById("hotkey-hint");
        \\  disp.textContent="Press keys...";
        \\  hint.textContent="Listening... (Esc to cancel)";
        \\  hint.classList.remove("error");
        \\  const onKey=function(e){
        \\    e.preventDefault();
        \\    if(e.key==="Escape"){
        \\      document.removeEventListener("keydown",onKey,true);
        \\      disp.textContent=hotkeyLabel(pendingHotkeyMods,pendingHotkeyKey);
        \\      hint.textContent="Default: Ctrl+Alt+L";
        \\      return;
        \\    }
        \\    if(["Control","Alt","Shift","Meta"].includes(e.key)) return;
        \\    const key=e.key.length===1?e.key.toUpperCase():e.key;
        \\    const isLetterOrDigit=/^[A-Z0-9]$/.test(key);
        \\    let mods=0;
        \\    if(e.ctrlKey)mods|=HOTKEY_MOD_CTRL;
        \\    if(e.altKey)mods|=HOTKEY_MOD_ALT;
        \\    if(e.shiftKey)mods|=HOTKEY_MOD_SHIFT;
        \\    if(e.metaKey)mods|=HOTKEY_MOD_WIN;
        \\    if(!isLetterOrDigit||mods===0){
        \\      hint.textContent="Use a letter/number key with at least one modifier.";
        \\      hint.classList.add("error");
        \\      return;
        \\    }
        \\    pendingHotkeyMods=mods;
        \\    pendingHotkeyKey=key.charCodeAt(0);
        \\    disp.textContent=hotkeyLabel(mods,pendingHotkeyKey);
        \\    hint.textContent="Default: Ctrl+Alt+L";
        \\    hint.classList.remove("error");
        \\    document.removeEventListener("keydown",onKey,true);
        \\  };
        \\  document.addEventListener("keydown",onKey,true);
        \\}
    );
```

- [ ] **Step 4: Wire the recorded value into `openSettings` and `saveSettingsForm`**

Replace `src/main.zig:1483-1494`:

```zig
        \\async function openSettings(){
        \\  try{
        \\    if(window.zero&&window.zero.invoke){
        \\      const s = await window.zero.invoke("app.get-settings", {});
        \\      populateHourSelect("set-start", s.work_start_hour);
        \\      populateHourSelect("set-end", s.work_end_hour);
        \\      document.getElementById("set-theme").value = s.theme;
        \\      document.getElementById("set-fillgaps").checked = !!s.fill_gaps;
        \\    }
        \\  }catch(e){console.error(e)}
        \\  document.getElementById("settings-overlay").style.display = "flex";
        \\}
```

with:

```zig
        \\async function openSettings(){
        \\  try{
        \\    if(window.zero&&window.zero.invoke){
        \\      const s = await window.zero.invoke("app.get-settings", {});
        \\      populateHourSelect("set-start", s.work_start_hour);
        \\      populateHourSelect("set-end", s.work_end_hour);
        \\      document.getElementById("set-theme").value = s.theme;
        \\      document.getElementById("set-fillgaps").checked = !!s.fill_gaps;
        \\      pendingHotkeyMods = s.hotkey_mods;
        \\      pendingHotkeyKey = s.hotkey_key;
        \\      document.getElementById("set-hotkey-display").textContent = hotkeyLabel(pendingHotkeyMods, pendingHotkeyKey);
        \\      const hint = document.getElementById("hotkey-hint");
        \\      hint.textContent = "Default: Ctrl+Alt+L";
        \\      hint.classList.remove("error");
        \\    }
        \\  }catch(e){console.error(e)}
        \\  document.getElementById("settings-overlay").style.display = "flex";
        \\}
```

Replace `src/main.zig:1504-1519`:

```zig
        \\async function saveSettingsForm(){
        \\  try{
        \\    if(window.zero&&window.zero.invoke){
        \\      const payload = {
        \\        work_start_hour: parseInt(document.getElementById("set-start").value, 10),
        \\        work_end_hour: parseInt(document.getElementById("set-end").value, 10),
        \\        theme: document.getElementById("set-theme").value,
        \\        fill_gaps: document.getElementById("set-fillgaps").checked
        \\      };
        \\      const r = await window.zero.invoke("app.save-settings", payload);
        \\      applyTheme(payload.theme);
        \\      applyResult(r);
        \\    }
        \\  }catch(e){console.error(e)}
        \\  closeSettings();
        \\}
```

with:

```zig
        \\async function saveSettingsForm(){
        \\  try{
        \\    if(window.zero&&window.zero.invoke){
        \\      const payload = {
        \\        work_start_hour: parseInt(document.getElementById("set-start").value, 10),
        \\        work_end_hour: parseInt(document.getElementById("set-end").value, 10),
        \\        theme: document.getElementById("set-theme").value,
        \\        fill_gaps: document.getElementById("set-fillgaps").checked,
        \\        hotkey_mods: pendingHotkeyMods,
        \\        hotkey_key: pendingHotkeyKey
        \\      };
        \\      const r = await window.zero.invoke("app.save-settings", payload);
        \\      applyTheme(payload.theme);
        \\      applyResult(r);
        \\    }
        \\  }catch(e){console.error(e)}
        \\  closeSettings();
        \\}
```

- [ ] **Step 5: Build and run the test suite**

Run: `native test`
Expected: `Build Summary: 7/7 steps succeeded; 11/11 tests passed` (the `html generation produces valid output` test still passes since it only checks for `"Work Log"`/`"Monday"`/`"Friday"` substrings, unaffected by this markup)

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "Add press-to-record global shortcut field to the Settings modal"
```

---

### Task 5: Reword static hotkey references to describe a changeable default

**Files:**
- Modify: `src/main.zig:66`, `src/main.zig:285`, `src/main.zig:333`, `src/main.zig:1299`, `src/main.zig:1361`, `src/main.zig:1364`, `src/main.zig:2055`, `README.md:3-6,14-15,21`

**Interfaces:**
- Consumes: nothing new — pure text edits, no behavior change.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Update the tray item label**

In `src/main.zig:66`, replace:

```zig
    .{ .id = 1, .label = "Store Clipboard (Ctrl+Alt+L)", .command = "app.store" },
```

with:

```zig
    .{ .id = 1, .label = "Store Clipboard (default Ctrl+Alt+L)", .command = "app.store" },
```

- [ ] **Step 2: Update the two tray tooltip occurrences**

In `src/main.zig:285` and `src/main.zig:333`, replace both occurrences of:

```zig
            .tooltip = "Work Log - Ctrl+Alt+L to store",
```

with:

```zig
            .tooltip = "Work Log - your shortcut (default Ctrl+Alt+L) to store",
```

- [ ] **Step 3: Update the header sub-text**

In `src/main.zig:1299`, replace:

```zig
        \\<p class="sub">Select text + <b>Ctrl+Alt+L</b> anywhere to store. Hover entries to see full text.</p>
```

with:

```zig
        \\<p class="sub">Select text + your shortcut (default <b>Ctrl+Alt+L</b>) anywhere to store. Hover entries to see full text.</p>
```

- [ ] **Step 4: Update the About-modal instructions**

In `src/main.zig:1361` and `src/main.zig:1364`, replace:

```zig
        \\<li>Select any text (like a Jira ticket URL) in any application and press <b>Ctrl+Alt+L</b> to save it under today's date - no need to switch to this app first.</li>
        \\<li>Browse what you logged in the <b>Month</b>, <b>Week</b>, or <b>Day</b> view. Hover an entry to see its full text, and use the &times; to delete one.</li>
        \\<li><b>Analytics</b> shows how much time you spent on each ticket, based on the gap between when each one was logged.</li>
        \\<li>Use the gear icon to set your work hours, theme, fill-gaps behavior, and to export a CSV backup.</li>
```

with:

```zig
        \\<li>Select any text (like a Jira ticket URL) in any application and press your configured shortcut (default <b>Ctrl+Alt+L</b>) to save it under today's date - no need to switch to this app first.</li>
        \\<li>Browse what you logged in the <b>Month</b>, <b>Week</b>, or <b>Day</b> view. Hover an entry to see its full text, and use the &times; to delete one.</li>
        \\<li><b>Analytics</b> shows how much time you spent on each ticket, based on the gap between when each one was logged.</li>
        \\<li>Use the gear icon to set your work hours, theme, global shortcut, fill-gaps behavior, and to export a CSV backup.</li>
```

- [ ] **Step 5: Update the default status bar text**

In `src/main.zig:2055`, replace:

```zig
    setStatus("Ready. Select text + Ctrl+Alt+L to store.");
```

with:

```zig
    setStatus("Ready. Select text + your shortcut (default Ctrl+Alt+L) to store.");
```

- [ ] **Step 6: Update `README.md`**

Replace lines 3-6:

```md
A Windows desktop tool for logging what you work on without breaking your
flow. Select any text (like a Jira ticket URL) in any application, press
**Ctrl+Alt+L**, and it's saved under today's date — no need to switch to
this app first.
```

with:

```md
A Windows desktop tool for logging what you work on without breaking your
flow. Select any text (like a Jira ticket URL) in any application, press
your global shortcut (**Ctrl+Alt+L** by default, changeable in Settings),
and it's saved under today's date — no need to switch to this app first.
```

Replace lines 14-15:

```md
- **Global hotkey capture** — Ctrl+Alt+L stores the current text selection
  under today's date from anywhere on the desktop.
```

with:

```md
- **Global hotkey capture** — a configurable shortcut (Ctrl+Alt+L by
  default) stores the current text selection under today's date from
  anywhere on the desktop.
```

Replace line 21:

```md
- **Settings** — working hours, light/dark/auto theme, fill-gaps behavior.
```

with:

```md
- **Settings** — working hours, light/dark/auto theme, global shortcut,
  fill-gaps behavior.
```

- [ ] **Step 7: Build and run the test suite**

Run: `native test`
Expected: `Build Summary: 7/7 steps succeeded; 11/11 tests passed`

- [ ] **Step 8: Commit**

```bash
git add src/main.zig README.md
git commit -m "Reword hotkey references to describe a changeable default, not a fixed combo"
```

---

### Task 6: Manual end-to-end verification

**Files:** none (verification only)

**Interfaces:**
- Consumes: the fully assembled feature from Tasks 1-5.
- Produces: nothing — this task just confirms the feature works in the running app.

- [ ] **Step 1: Build and launch the app**

Run: `native dev`
Expected: the app window opens showing the calendar view with no build errors.

- [ ] **Step 2: Confirm the default combo still works**

Select some text in any other application, press Ctrl+Alt+L.
Expected: a "Checking entry..." then "Entry saved" toast appears, and the entry shows up under today's date back in Work Log.

- [ ] **Step 3: Change the shortcut**

Open Settings (gear icon) → click "Record" next to "Global shortcut" → press e.g. Ctrl+Shift+K.
Expected: the field updates to show "Ctrl+Shift+K". Click Save.

- [ ] **Step 4: Confirm the old combo no longer triggers and the new one does**

Select text elsewhere, press Ctrl+Alt+L.
Expected: nothing happens (no toast, no new entry).

Select text elsewhere, press Ctrl+Shift+K.
Expected: the entry is captured as in Step 2.

- [ ] **Step 5: Confirm persistence across restart**

Close the app fully and relaunch with `native dev`. Open Settings again.
Expected: the "Global shortcut" field still shows "Ctrl+Shift+K" (read from `settings.txt`), and pressing Ctrl+Shift+K still captures — confirming the value survived the restart.

- [ ] **Step 6: Reset to default and confirm the About/status text still make sense**

In Settings, click "Reset" next to the shortcut field, Save. Open the About panel and check the status bar text at the bottom of the window.
Expected: both read "your shortcut (default Ctrl+Alt+L)" rather than asserting a specific unchangeable combo, and Ctrl+Alt+L captures again.
