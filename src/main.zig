const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const builtin = @import("builtin");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const window_width: f32 = 1000;
const window_height: f32 = 700;

const max_entries = 512;
const max_text_len = 512;
const day_names = [7][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
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

const Entry = struct {
    date: [10]u8,
    timestamp: i64,
    text_buf: [max_text_len]u8,
    text_len: usize,
};

const platform = native_sdk.platform;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_window,
    native_sdk.security.permission_command,
    native_sdk.security.permission_clipboard,
};
const bridge_origins = [_][]const u8{ "zero://inline", "zero://app" };
const clipboard_permission = [_][]const u8{native_sdk.security.permission_clipboard};
const command_permission = [_][]const u8{native_sdk.security.permission_command};
const builtin_policies = [_]native_sdk.BridgeCommandPolicy{
    .{ .name = "native-sdk.clipboard.readText", .permissions = &clipboard_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.clipboard.writeText", .permissions = &clipboard_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.command.invoke", .permissions = &command_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.command.list", .permissions = &command_permission, .origins = &bridge_origins },
    .{ .name = "native-sdk.dialog.saveFile", .permissions = &.{}, .origins = &bridge_origins },
};
const app_bridge_policies = [_]native_sdk.BridgeCommandPolicy{
    .{ .name = "app.get-calendar", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.nav-prev", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.nav-next", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.nav-today", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.set-view-month", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.set-view-week", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.set-view-day", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.set-view-analytics", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.get-settings", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.save-settings", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.export-data", .permissions = &.{}, .origins = &bridge_origins },
    .{ .name = "app.toggle-weekends", .permissions = &.{}, .origins = &bridge_origins },
};
const tray_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Store Clipboard (Ctrl+Alt+L)", .command = "app.store" },
    .{ .id = 2, .label = "Show Window" },
};
const tray_icon_for_light_taskbar = "assets/icon.ico";
const tray_icon_for_dark_taskbar = "assets/icon-white.ico";

fn trayIconPathFor(scheme: platform.ColorScheme) []const u8 {
    return switch (scheme) {
        .dark => tray_icon_for_dark_taskbar,
        .light => tray_icon_for_light_taskbar,
    };
}
const shell_views = [_]native_sdk.ShellView{
    .{ .label = "main", .kind = .webview, .url = "zero://inline", .fill = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Work Log",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

var hotkey_was_down: bool = false;

const WorkLogApp = struct {
    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,
    data_path_buf: [512]u8 = undefined,
    data_path_len: usize = 0,
    html_buf: [64 * 1024]u8 = undefined,
    html_len: usize = 0,
    pending_clipboard_read: bool = false,
    started: bool = false,
    handlers: [12]native_sdk.bridge.Handler = undefined,

    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "work-log",
            .source = native_sdk.WebViewSource.html(&self.html_buf),
            .source_fn = source,
            .scene_fn = scene,
            .start_fn = start,
            .event_fn = event,
        };
    }

    fn bridge(self: *@This()) native_sdk.BridgeDispatcher {
        self.handlers = .{
            .{ .name = "app.get-calendar", .context = self, .invoke_fn = getCalendarHandler },
            .{ .name = "app.nav-prev", .context = self, .invoke_fn = navPrevHandler },
            .{ .name = "app.nav-next", .context = self, .invoke_fn = navNextHandler },
            .{ .name = "app.nav-today", .context = self, .invoke_fn = navTodayHandler },
            .{ .name = "app.set-view-month", .context = self, .invoke_fn = setViewMonthHandler },
            .{ .name = "app.set-view-week", .context = self, .invoke_fn = setViewWeekHandler },
            .{ .name = "app.set-view-day", .context = self, .invoke_fn = setViewDayHandler },
            .{ .name = "app.set-view-analytics", .context = self, .invoke_fn = setViewAnalyticsHandler },
            .{ .name = "app.get-settings", .context = self, .invoke_fn = getSettingsHandler },
            .{ .name = "app.save-settings", .context = self, .invoke_fn = saveSettingsHandler },
            .{ .name = "app.export-data", .context = self, .invoke_fn = exportDataHandler },
            .{ .name = "app.toggle-weekends", .context = self, .invoke_fn = toggleWeekendsHandler },
        };
        return .{
            .policy = .{ .enabled = true, .commands = &app_bridge_policies },
            .registry = .{ .handlers = &self.handlers },
        };
    }

    fn renderCurrentViewJson(self: *@This(), output: []u8) []const u8 {
        var cal_buf: [16 * 1024]u8 = undefined;
        const cal_len = writeViewBody(&cal_buf, 0, self.entries[0..self.entry_count]);

        var pos: usize = 0;
        pos = appendStr(output, pos, "{\"html\":");
        const html_json = native_sdk.bridge.writeJsonStringValue(output[pos..], cal_buf[0..cal_len]);
        pos += html_json.len;
        pos = appendStr(output, pos, ",\"status\":");
        const status_json = native_sdk.bridge.writeJsonStringValue(output[pos..], currentStatus());
        pos += status_json.len;
        pos = appendStr(output, pos, "}");
        return output[0..pos];
    }

    fn getCalendarHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.renderCurrentViewJson(output);
    }

    fn navPrevHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        navigateView(-1);
        return self.renderCurrentViewJson(output);
    }

    fn navNextHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        navigateView(1);
        return self.renderCurrentViewJson(output);
    }

    fn navTodayHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        resetViewToToday();
        return self.renderCurrentViewJson(output);
    }

    fn setViewMonthHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        view_mode = .month;
        return self.renderCurrentViewJson(output);
    }

    fn setViewWeekHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        view_mode = .week;
        return self.renderCurrentViewJson(output);
    }

    fn setViewDayHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        view_mode = .day;
        return self.renderCurrentViewJson(output);
    }

    fn setViewAnalyticsHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        view_mode = .analytics;
        return self.renderCurrentViewJson(output);
    }

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

        self.saveSettings();
        return self.renderCurrentViewJson(output);
    }

    fn toggleWeekendsHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        _ = invocation;
        const self: *@This() = @ptrCast(@alignCast(context));
        show_weekends = !show_weekends;
        self.saveSettings();
        return self.renderCurrentViewJson(output);
    }

    fn exportDataHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const payload = invocation.request.payload;

        var path_buf: [512]u8 = undefined;
        const path = jsonStringField(payload, "path", &path_buf) orelse {
            return std.fmt.bufPrint(output, "{{\"ok\":false}}", .{}) catch "{\"ok\":false}";
        };
        const ok = self.writeEntriesToPath(path);
        return std.fmt.bufPrint(output, "{{\"ok\":{s}}}", .{@as([]const u8, if (ok) "true" else "false")}) catch "{\"ok\":false}";
    }

    fn scene(_: *anyopaque) anyerror!native_sdk.ShellConfig {
        return shell_scene;
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        return native_sdk.WebViewSource.html(self.html_buf[0..self.html_len]);
    }

    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.started = true;
        debugLog("start: app started, creating tray and timer");
        try runtime.createTray(.{
            .icon_path = trayIconPathFor(runtime.appearance.color_scheme),
            .tooltip = "Work Log - Ctrl+Alt+L to store",
            .items = &tray_items,
        });
        try runtime.startTimer(hotkey_timer_id, hotkey_interval_ns, true);
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |cmd| {
                debugLogWithText("command received: ", cmd.name);
                if (std.mem.eql(u8, cmd.name, "app.store")) {
                    self.handleStore(runtime, cmd.window_id);
                } else if (std.mem.startsWith(u8, cmd.name, "app.copy-day-") and cmd.name.len >= 23) {
                    self.handleCopyDay(runtime, cmd.window_id, cmd.name[13..23]);
                } else if (std.mem.startsWith(u8, cmd.name, "app.delete-")) {
                    self.handleDelete(runtime, cmd.window_id, cmd.name[11..]);
                }
            },
            .timer => |timer| {
                if (timer.id == hotkey_timer_id) {
                    if (checkGlobalHotkey()) {
                        showToast(runtime, "Checking entry...", "");
                        simulateCtrlC();
                        self.pending_clipboard_read = true;
                        runtime.startTimer(clipboard_read_timer_id, clipboard_read_delay_ns, false) catch {};
                    }
                } else if (timer.id == clipboard_read_timer_id) {
                    if (self.pending_clipboard_read) {
                        self.pending_clipboard_read = false;
                        self.handleStore(runtime, 1);
                    }
                }
            },
            .lifecycle => |lifecycle| switch (lifecycle) {
                .activate => {
                    debugLog("lifecycle: activate - reloading data");
                    self.loadFromFile();
                    self.rebuildHtml();
                    if (self.started) {
                        self.reloadWebView(runtime, 1);
                    }
                },
                else => {},
            },
            .appearance_changed => |appearance| {
                runtime.createTray(.{
                    .icon_path = trayIconPathFor(appearance.color_scheme),
                    .tooltip = "Work Log - Ctrl+Alt+L to store",
                    .items = &tray_items,
                }) catch {};
            },
            .shortcut, .effects_wake, .audio, .files_dropped, .gpu_surface_frame, .gpu_surface_resized, .gpu_surface_input, .canvas_widget_pointer, .canvas_widget_keyboard, .canvas_widget_scroll, .canvas_widget_file_drop, .canvas_widget_drag, .canvas_widget_context_menu, .canvas_widget_context_menu_request, .canvas_widget_dismiss, .canvas_widget_context_press, .canvas_widget_resize, .canvas_widget_change, .window_closed, .automation_provenance => {},
        }
    }

    fn handleStore(self: *@This(), runtime: *native_sdk.Runtime, window_id: platform.WindowId) void {
        debugLog("handleStore: reading clipboard...");
        var clip_buf: [max_text_len]u8 = undefined;
        const clip_text = readSystemClipboard(&clip_buf) orelse {
            debugLog("handleStore: clipboard returned null (no text)");
            setStatus("No text in clipboard.");
            showToast(runtime, "No text found", "Select some text before pressing the hotkey.");
            return;
        };
        if (clip_text.len == 0) {
            debugLog("handleStore: clipboard is empty");
            setStatus("Clipboard is empty.");
            showToast(runtime, "No text found", "Select some text before pressing the hotkey.");
            return;
        }
        debugLogWithText("handleStore: got clipboard text: ", clip_text);

        const today = todayDateStr();

        if (self.isDuplicate(&today, clip_text)) {
            debugLog("handleStore: duplicate, skipping");
            setStatus("Already stored today.");
            showToast(runtime, "Duplicate entry", "Already stored today.");
            return;
        }

        if (self.entry_count >= max_entries) {
            setStatus("Storage full.");
            showToast(runtime, "Storage full", "Export or clear old entries.");
            return;
        }

        var entry = &self.entries[self.entry_count];
        entry.date = today;
        entry.timestamp = nowTimestamp();
        const copy_len = @min(clip_text.len, max_text_len);
        @memcpy(entry.text_buf[0..copy_len], clip_text[0..copy_len]);
        entry.text_len = copy_len;
        self.entry_count += 1;

        self.saveToFile();
        debugLog("handleStore: saved to file, rebuilding HTML");
        self.rebuildHtml();
        self.reloadWebView(runtime, window_id);

        var store_status_buf: [128]u8 = undefined;
        const display_len = @min(copy_len, 60);
        const status = std.fmt.bufPrint(&store_status_buf, "Stored: {s}", .{clip_text[0..display_len]}) catch "Stored entry.";
        setStatus(status);
        showToast(runtime, "Entry saved", clip_text[0..display_len]);
    }

    fn handleCopyDay(self: *@This(), runtime: *native_sdk.Runtime, window_id: platform.WindowId, target_date: []const u8) void {
        _ = runtime;
        _ = window_id;
        if (target_date.len != 10) return;

        var result_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        for (self.entries[0..self.entry_count]) |entry| {
            if (std.mem.eql(u8, &entry.date, target_date[0..10])) {
                const text = entry.text_buf[0..entry.text_len];
                if (pos + text.len + 1 <= result_buf.len) {
                    if (pos > 0) {
                        result_buf[pos] = '\n';
                        pos += 1;
                    }
                    @memcpy(result_buf[pos .. pos + text.len], text);
                    pos += text.len;
                }
            }
        }

        if (pos == 0) {
            setStatus("No entries for this day.");
            return;
        }

        writeSystemClipboard(result_buf[0..pos]);
        setStatus("Copied day entries to clipboard.");
    }

    fn handleDelete(self: *@This(), runtime: *native_sdk.Runtime, window_id: platform.WindowId, key: []const u8) void {
        debugLogWithText("handleDelete: key=", key);
        const sep = std.mem.indexOf(u8, key, "-idx-") orelse return;
        const date_str = key[0..sep];
        if (date_str.len != 10) return;
        const idx_str = key[sep + 5 ..];

        var target_idx: usize = 0;
        for (idx_str) |c| {
            if (c < '0' or c > '9') return;
            target_idx = target_idx * 10 + (c - '0');
        }

        var match_count: usize = 0;
        var delete_pos: ?usize = null;
        for (self.entries[0..self.entry_count], 0..) |entry, i| {
            if (std.mem.eql(u8, &entry.date, date_str[0..10])) {
                if (match_count == target_idx) {
                    delete_pos = i;
                    break;
                }
                match_count += 1;
            }
        }

        if (delete_pos) |dp| {
            debugLog("handleDelete: found entry, removing");
            var i = dp;
            while (i + 1 < self.entry_count) : (i += 1) {
                self.entries[i] = self.entries[i + 1];
            }
            self.entry_count -= 1;
            self.saveToFile();
            self.rebuildHtml();
            self.reloadWebView(runtime, window_id);
            setStatus("Entry deleted.");
        } else {
            debugLog("handleDelete: entry not found");
        }
    }

    fn isDuplicate(self: *@This(), date: *const [10]u8, text: []const u8) bool {
        for (self.entries[0..self.entry_count]) |entry| {
            if (std.mem.eql(u8, &entry.date, date)) {
                const entry_text = entry.text_buf[0..entry.text_len];
                if (std.mem.eql(u8, entry_text, text[0..@min(text.len, max_text_len)])) {
                    return true;
                }
            }
        }
        return false;
    }

    fn rebuildHtml(self: *@This()) void {
        self.html_len = writeHtmlToBuffer(&self.html_buf, self.entries[0..self.entry_count]);
        @memset(self.html_buf[self.html_len..], 0);
    }

    fn reloadWebView(self: *@This(), runtime: *native_sdk.Runtime, window_id: platform.WindowId) void {
        _ = self;
        _ = runtime;
        _ = window_id;
        debugLog("reloadWebView: content updated in buffer, JS polls app.get-calendar to pick it up");
    }

    fn initDataPath(self: *@This()) void {
        if (builtin.os.tag == .windows) {
            var env_buf: [260]u16 = undefined;
            const len = w32.GetEnvironmentVariableW(&[_:0]u16{ 'A', 'P', 'P', 'D', 'A', 'T', 'A' }, &env_buf, 260);
            if (len > 0 and len < 260) {
                var utf8_pos: usize = 0;
                for (0..len) |i| {
                    const cp: u21 = env_buf[i];
                    if (cp < 0x80 and utf8_pos < self.data_path_buf.len) {
                        self.data_path_buf[utf8_pos] = @intCast(cp);
                        utf8_pos += 1;
                    }
                }
                const suffix = "\\work-log\\data.csv";
                const dir_suffix = "\\work-log";
                if (utf8_pos + suffix.len < self.data_path_buf.len) {
                    var dir_path_buf: [512]u8 = undefined;
                    @memcpy(dir_path_buf[0..utf8_pos], self.data_path_buf[0..utf8_pos]);
                    @memcpy(dir_path_buf[utf8_pos .. utf8_pos + dir_suffix.len], dir_suffix);
                    dir_path_buf[utf8_pos + dir_suffix.len] = 0;
                    var wide_dir: [512]u16 = undefined;
                    for (0..utf8_pos + dir_suffix.len) |i| {
                        wide_dir[i] = dir_path_buf[i];
                    }
                    wide_dir[utf8_pos + dir_suffix.len] = 0;
                    _ = w32.CreateDirectoryW(@ptrCast(&wide_dir), null);

                    @memcpy(self.data_path_buf[utf8_pos .. utf8_pos + suffix.len], suffix);
                    self.data_path_len = utf8_pos + suffix.len;
                }
            }
        }
    }

    fn dataPath(self: *@This()) []const u8 {
        return self.data_path_buf[0..self.data_path_len];
    }

    fn settingsPath(self: *@This(), buf: *[512]u8) []const u8 {
        if (self.data_path_len < 8) return buf[0..0];
        const dir_len = self.data_path_len - 8; // strip trailing "data.csv"
        @memcpy(buf[0..dir_len], self.data_path_buf[0..dir_len]);
        const suffix = "settings.txt";
        @memcpy(buf[dir_len .. dir_len + suffix.len], suffix);
        return buf[0 .. dir_len + suffix.len];
    }

    fn loadSettings(self: *@This()) void {
        if (builtin.os.tag != .windows) return;
        var path_buf: [512]u8 = undefined;
        const path = self.settingsPath(&path_buf);
        if (path.len == 0) return;
        var wide_path: [512]u16 = undefined;
        for (0..path.len) |i| wide_path[i] = path[i];
        wide_path[path.len] = 0;

        const handle = w32.CreateFileW(@ptrCast(&wide_path), w32.GENERIC_READ, w32.FILE_SHARE_READ, null, w32.OPEN_EXISTING, w32.FILE_ATTRIBUTE_NORMAL, null);
        if (handle == w32.INVALID_HANDLE_VALUE) return;
        defer _ = w32.CloseHandle(handle);

        var file_buf: [1024]u8 = undefined;
        var bytes_read: u32 = 0;
        if (w32.ReadFile(handle, &file_buf, file_buf.len, &bytes_read, null) == 0) return;
        const data = file_buf[0..bytes_read];

        var start_pos: usize = 0;
        while (start_pos < data.len) {
            const nl = std.mem.indexOfScalarPos(u8, data, start_pos, '\n') orelse data.len;
            var line = data[start_pos..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            start_pos = nl + 1;

            const eq = std.mem.indexOf(u8, line, "=") orelse continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];
            if (std.mem.eql(u8, key, "work_start_hour")) {
                work_start_hour = std.fmt.parseUnsigned(u8, value, 10) catch work_start_hour;
            } else if (std.mem.eql(u8, key, "work_end_hour")) {
                work_end_hour = std.fmt.parseUnsigned(u8, value, 10) catch work_end_hour;
            } else if (std.mem.eql(u8, key, "theme")) {
                if (std.mem.eql(u8, value, "light")) {
                    app_theme = .light;
                } else if (std.mem.eql(u8, value, "dark")) {
                    app_theme = .dark;
                } else {
                    app_theme = .auto;
                }
            } else if (std.mem.eql(u8, key, "fill_gaps")) {
                fill_gaps = std.mem.eql(u8, value, "1");
            } else if (std.mem.eql(u8, key, "show_weekends")) {
                show_weekends = std.mem.eql(u8, value, "1");
            }
        }
    }

    fn saveSettings(self: *@This()) void {
        if (builtin.os.tag != .windows) return;
        var path_buf: [512]u8 = undefined;
        const path = self.settingsPath(&path_buf);
        if (path.len == 0) return;
        var wide_path: [512]u16 = undefined;
        for (0..path.len) |i| wide_path[i] = path[i];
        wide_path[path.len] = 0;

        const handle = w32.CreateFileW(@ptrCast(&wide_path), w32.GENERIC_WRITE, 0, null, w32.CREATE_ALWAYS, w32.FILE_ATTRIBUTE_NORMAL, null);
        if (handle == w32.INVALID_HANDLE_VALUE) return;
        defer _ = w32.CloseHandle(handle);

        const theme_str = switch (app_theme) {
            .auto => "auto",
            .light => "light",
            .dark => "dark",
        };
        var write_buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&write_buf, "work_start_hour={d}\nwork_end_hour={d}\ntheme={s}\nfill_gaps={d}\nshow_weekends={d}\n", .{
            work_start_hour,
            work_end_hour,
            theme_str,
            @as(u8, if (fill_gaps) 1 else 0),
            @as(u8, if (show_weekends) 1 else 0),
        }) catch return;
        var written: u32 = 0;
        _ = w32.WriteFile(handle, content.ptr, @intCast(content.len), &written, null);
    }

    fn saveToFile(self: *@This()) void {
        if (self.data_path_len == 0) return;
        _ = self.writeEntriesToPath(self.dataPath());
    }

    /// Writes all in-memory entries, in the same tab-separated format as
    /// the primary data file, to an arbitrary destination path - used for
    /// both the primary save and user-triggered backup export.
    fn writeEntriesToPath(self: *@This(), path: []const u8) bool {
        if (builtin.os.tag != .windows) return false;
        if (path.len == 0 or path.len >= 512) return false;
        var wide_path: [512]u16 = undefined;
        for (0..path.len) |i| {
            wide_path[i] = path[i];
        }
        wide_path[path.len] = 0;

        const handle = w32.CreateFileW(
            @ptrCast(&wide_path),
            w32.GENERIC_WRITE,
            0,
            null,
            w32.CREATE_ALWAYS,
            w32.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == w32.INVALID_HANDLE_VALUE) return false;
        defer _ = w32.CloseHandle(handle);

        var write_buf: [1024]u8 = undefined;
        for (self.entries[0..self.entry_count]) |entry| {
            const line = std.fmt.bufPrint(&write_buf, "{s}\t{d}\t{s}\n", .{ entry.date, entry.timestamp, entry.text_buf[0..entry.text_len] }) catch continue;
            var written: u32 = 0;
            _ = w32.WriteFile(handle, line.ptr, @intCast(line.len), &written, null);
        }
        return true;
    }

    fn loadFromFile(self: *@This()) void {
        if (self.data_path_len == 0) return;
        var wide_path: [512]u16 = undefined;
        const path = self.dataPath();
        for (0..path.len) |i| {
            wide_path[i] = path[i];
        }
        wide_path[path.len] = 0;

        if (builtin.os.tag == .windows) {
            const handle = w32.CreateFileW(
                @ptrCast(&wide_path),
                w32.GENERIC_READ,
                w32.FILE_SHARE_READ,
                null,
                w32.OPEN_EXISTING,
                w32.FILE_ATTRIBUTE_NORMAL,
                null,
            );
            if (handle == w32.INVALID_HANDLE_VALUE) return;
            defer _ = w32.CloseHandle(handle);

            var file_buf: [32768]u8 = undefined;
            var bytes_read: u32 = 0;
            if (w32.ReadFile(handle, &file_buf, file_buf.len, &bytes_read, null) == 0) return;

            self.entry_count = 0;
            var start_pos: usize = 0;
            const data = file_buf[0..bytes_read];
            while (start_pos < data.len) {
                const nl = std.mem.indexOfScalarPos(u8, data, start_pos, '\n') orelse data.len;
                const line_raw = data[start_pos..nl];
                var line_end = line_raw.len;
                while (line_end > 0 and line_raw[line_end - 1] == '\r') line_end -= 1;
                const line = line_raw[0..line_end];
                start_pos = nl + 1;

                if (line.len < 12) continue;
                const tab_idx = std.mem.indexOf(u8, line, "\t") orelse continue;
                if (tab_idx != 10) continue;

                const date_str = line[0..10];
                const rest = line[11..];
                if (rest.len == 0 or self.entry_count >= max_entries) continue;

                var timestamp: i64 = 0;
                var text: []const u8 = rest;
                if (std.mem.indexOf(u8, rest, "\t")) |tab2| {
                    if (std.fmt.parseInt(i64, rest[0..tab2], 10)) |ts| {
                        timestamp = ts;
                        text = rest[tab2 + 1 ..];
                    } else |_| {
                        // Not a numeric timestamp field - legacy line whose
                        // text happens to contain a literal tab; keep it
                        // whole and fall back to a midnight timestamp below.
                    }
                }
                if (timestamp == 0) {
                    const pd = parseDateStr(date_str);
                    timestamp = daysFromCivil(pd.year, pd.month, pd.day) * 86400;
                }
                if (text.len == 0) continue;

                var entry = &self.entries[self.entry_count];
                @memcpy(&entry.date, date_str);
                entry.timestamp = timestamp;
                const copy_len = @min(text.len, max_text_len);
                @memcpy(entry.text_buf[0..copy_len], text[0..copy_len]);
                entry.text_len = copy_len;
                self.entry_count += 1;
            }
        }
    }
};

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

var status_buf: [128]u8 = undefined;
var status_len: usize = 0;

fn setStatus(text: []const u8) void {
    const len = @min(text.len, status_buf.len);
    @memcpy(status_buf[0..len], text[0..len]);
    status_len = len;
}

fn currentStatus() []const u8 {
    return status_buf[0..status_len];
}

fn showToast(runtime: *native_sdk.Runtime, title: []const u8, body: []const u8) void {
    runtime.showNotification(.{ .title = title, .body = body }) catch |err| {
        debugLogWithText("showToast: failed: ", @errorName(err));
    };
}

pub fn todayDateStr() [10]u8 {
    if (builtin.os.tag == .windows) {
        var st: w32.SYSTEMTIME = undefined;
        w32.GetLocalTime(&st);
        var buf: [10]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
            @as(u32, st.wYear),
            @as(u32, st.wMonth),
            @as(u32, st.wDay),
        }) catch {};
        return buf;
    }
    return "0000-00-00".*;
}

/// Seconds since 1970-01-01 in local time (not true UTC epoch, but internally
/// consistent for diffing durations between entries logged on this machine).
fn nowTimestamp() i64 {
    if (builtin.os.tag == .windows) {
        var st: w32.SYSTEMTIME = undefined;
        w32.GetLocalTime(&st);
        const days = daysFromCivil(@intCast(st.wYear), st.wMonth, st.wDay);
        return days * 86400 + @as(i64, st.wHour) * 3600 + @as(i64, st.wMinute) * 60 + @as(i64, st.wSecond);
    }
    return 0;
}

const month_names = [12][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

fn daysInMonth(year: u16, month: u16) u16 {
    const dim = [12]u16{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month < 1 or month > 12) return 30;
    var d = dim[month - 1];
    if (month == 2 and isLeapYear(year)) d = 29;
    return d;
}

fn dayOfWeek(year: u16, month: u16, day: u16) u16 {
    var y: i32 = @intCast(year);
    var m: i32 = @intCast(month);
    if (m < 3) {
        m += 12;
        y -= 1;
    }
    const d: i32 = @intCast(day);
    const w = @mod(d + @divFloor(13 * (m + 1), 5) + y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400), 7);
    const dow: i32 = @mod(w + 5, 7);
    return @intCast(dow);
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn formatDate(year: u16, month: u16, day: u16) [10]u8 {
    var buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, year),
        @as(u32, month),
        @as(u32, day),
    }) catch {};
    return buf;
}

const DateParts = struct { year: u16, month: u16, day: u16 };

fn parseDateStr(date: []const u8) DateParts {
    const y = std.fmt.parseInt(u16, date[0..4], 10) catch 2026;
    const m = std.fmt.parseInt(u16, date[5..7], 10) catch 1;
    const d = std.fmt.parseInt(u16, date[8..10], 10) catch 1;
    return .{ .year = y, .month = m, .day = d };
}

/// Days-from-civil / civil-from-days: Howard Hinnant's proleptic Gregorian
/// day-count algorithm. Lets us shift a date by +/-N days across month and
/// year boundaries without hand-rolled carry logic.
fn daysFromCivil(year: i32, month: u16, day: u16) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else @as(i64, year);
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_in: i64) struct { year: i32, month: u16, day: u16 } {
    const z = z_in + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i32 = @intCast(if (m <= 2) y + 1 else y);
    return .{ .year = year, .month = @intCast(m), .day = @intCast(d) };
}

fn addDays(year: u16, month: u16, day: u16, delta: i64) struct { year: u16, month: u16, day: u16 } {
    const z = daysFromCivil(@intCast(year), month, day) + delta;
    const c = civilFromDays(z);
    return .{ .year = @intCast(c.year), .month = c.month, .day = c.day };
}

const ViewMode = enum { month, week, day, analytics };

var view_mode: ViewMode = .month;
var view_year: u16 = 2026;
var view_month: u16 = 1;
var view_day: u16 = 1;

fn resetViewToToday() void {
    const today = todayDateStr();
    const pd = parseDateStr(&today);
    view_year = pd.year;
    view_month = pd.month;
    view_day = pd.day;
}

fn navigateView(delta: i64) void {
    switch (view_mode) {
        .month => {
            var m: i32 = @as(i32, view_month) + @as(i32, @intCast(delta));
            var y: i32 = view_year;
            while (m < 1) {
                m += 12;
                y -= 1;
            }
            while (m > 12) {
                m -= 12;
                y += 1;
            }
            view_year = @intCast(y);
            view_month = @intCast(m);
            const dim = daysInMonth(view_year, view_month);
            if (view_day > dim) view_day = dim;
        },
        .week => {
            const c = addDays(view_year, view_month, view_day, delta * 7);
            view_year = c.year;
            view_month = c.month;
            view_day = c.day;
        },
        .day => {
            const c = addDays(view_year, view_month, view_day, delta);
            view_year = c.year;
            view_month = c.month;
            view_day = c.day;
        },
        .analytics => {},
    }
}

fn readSystemClipboard(out_buf: *[max_text_len]u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return readClipboardWindows(out_buf);
    return null;
}

fn writeSystemClipboard(text: []const u8) void {
    if (builtin.os.tag == .windows) writeClipboardWindows(text);
}

const w32 = struct {
    const BOOL = c_int;
    const HANDLE = std.os.windows.HANDLE;
    const HWND = std.os.windows.HWND;
    const UINT = std.os.windows.UINT;
    const DWORD = std.os.windows.DWORD;
    const LPVOID = *anyopaque;
    const SIZE_T = usize;
    const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;
    const CF_UNICODETEXT: UINT = 13;
    const GMEM_MOVEABLE: UINT = 0x0002;
    const GENERIC_READ: DWORD = 0x80000000;
    const GENERIC_WRITE: DWORD = 0x40000000;
    const CREATE_ALWAYS: DWORD = 2;
    const OPEN_EXISTING: DWORD = 3;
    const OPEN_ALWAYS: DWORD = 4;
    const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
    const FILE_SHARE_READ: DWORD = 1;
    const FILE_SHARE_WRITE: DWORD = 2;
    const KEYEVENTF_KEYUP: DWORD = 0x0002;
    const FILE_END: DWORD = 2;

    const SECURITY_ATTRIBUTES = extern struct {
        nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
        lpSecurityDescriptor: ?*anyopaque = null,
        bInheritHandle: BOOL = 0,
    };

    extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(std.builtin.CallingConvention.winapi) BOOL;
    extern "user32" fn CloseClipboard() callconv(std.builtin.CallingConvention.winapi) BOOL;
    extern "user32" fn GetClipboardData(uFormat: UINT) callconv(std.builtin.CallingConvention.winapi) ?HANDLE;
    extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?HANDLE) callconv(std.builtin.CallingConvention.winapi) ?HANDLE;
    extern "user32" fn EmptyClipboard() callconv(std.builtin.CallingConvention.winapi) BOOL;
    extern "user32" fn GetAsyncKeyState(vKey: c_int) callconv(std.builtin.CallingConvention.winapi) c_short;
    extern "user32" fn keybd_event(bVk: u8, bScan: u8, dwFlags: DWORD, dwExtraInfo: usize) callconv(std.builtin.CallingConvention.winapi) void;
    extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: SIZE_T) callconv(std.builtin.CallingConvention.winapi) ?HANDLE;
    extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(std.builtin.CallingConvention.winapi) ?[*]align(1) u16;
    extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(std.builtin.CallingConvention.winapi) BOOL;
    extern "kernel32" fn GlobalFree(hMem: HANDLE) callconv(std.builtin.CallingConvention.winapi) ?HANDLE;
    extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: DWORD) callconv(std.builtin.CallingConvention.winapi) DWORD;
    extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*SECURITY_ATTRIBUTES) callconv(std.builtin.CallingConvention.winapi) BOOL;
    extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*SECURITY_ATTRIBUTES, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(std.builtin.CallingConvention.winapi) HANDLE;
    extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(std.builtin.CallingConvention.winapi) BOOL;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(std.builtin.CallingConvention.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(std.builtin.CallingConvention.winapi) BOOL;
    extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(std.builtin.CallingConvention.winapi) void;
    extern "kernel32" fn SetFilePointer(hFile: HANDLE, lDistanceToMove: c_long, lpDistanceToMoveHigh: ?*c_long, dwMoveMethod: DWORD) callconv(std.builtin.CallingConvention.winapi) DWORD;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(std.builtin.CallingConvention.winapi) void;

    const SYSTEMTIME = extern struct {
        wYear: u16,
        wMonth: u16,
        wDayOfWeek: u16,
        wDay: u16,
        wHour: u16,
        wMinute: u16,
        wSecond: u16,
        wMilliseconds: u16,
    };
};

var log_path_buf: [512]u8 = undefined;
var log_path_len: usize = 0;

fn initLogPath() void {
    if (builtin.os.tag != .windows) return;
    var env_buf: [260]u16 = undefined;
    const len = w32.GetEnvironmentVariableW(&[_:0]u16{ 'A', 'P', 'P', 'D', 'A', 'T', 'A' }, &env_buf, 260);
    if (len > 0 and len < 260) {
        var utf8_pos: usize = 0;
        for (0..len) |i| {
            const cp: u21 = env_buf[i];
            if (cp < 0x80 and utf8_pos < log_path_buf.len) {
                log_path_buf[utf8_pos] = @intCast(cp);
                utf8_pos += 1;
            }
        }
        const suffix = "\\work-log\\debug.log";
        if (utf8_pos + suffix.len < log_path_buf.len) {
            @memcpy(log_path_buf[utf8_pos .. utf8_pos + suffix.len], suffix);
            log_path_len = utf8_pos + suffix.len;
        }
    }
}

fn debugLog(msg: []const u8) void {
    if (builtin.os.tag != .windows) return;

    var path_buf: [512]u8 = undefined;
    var path_len: usize = 0;

    if (log_path_len > 0) {
        @memcpy(path_buf[0..log_path_len], log_path_buf[0..log_path_len]);
        path_len = log_path_len;
    } else {
        var env_buf: [260]u16 = undefined;
        const elen = w32.GetEnvironmentVariableW(&[_:0]u16{ 'A', 'P', 'P', 'D', 'A', 'T', 'A' }, &env_buf, 260);
        if (elen > 0 and elen < 260) {
            for (0..elen) |i| {
                const cp: u21 = env_buf[i];
                if (cp < 0x80 and path_len < path_buf.len) {
                    path_buf[path_len] = @intCast(cp);
                    path_len += 1;
                }
            }
            const suffix = "\\work-log\\debug.log";
            @memcpy(path_buf[path_len .. path_len + suffix.len], suffix);
            path_len += suffix.len;
            @memcpy(log_path_buf[0..path_len], path_buf[0..path_len]);
            log_path_len = path_len;
        } else return;
    }

    var wide_path: [512]u16 = undefined;
    for (0..path_len) |i| {
        wide_path[i] = path_buf[i];
    }
    wide_path[path_len] = 0;

    const handle = w32.CreateFileW(
        @ptrCast(&wide_path),
        w32.GENERIC_WRITE,
        w32.FILE_SHARE_READ | w32.FILE_SHARE_WRITE,
        null,
        w32.OPEN_ALWAYS,
        w32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == w32.INVALID_HANDLE_VALUE) return;
    defer _ = w32.CloseHandle(handle);

    _ = w32.SetFilePointer(handle, 0, null, w32.FILE_END);

    var ts_buf: [32]u8 = undefined;
    var st: w32.SYSTEMTIME = undefined;
    w32.GetLocalTime(&st);
    const ts = std.fmt.bufPrint(&ts_buf, "[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] ", .{
        @as(u32, st.wHour),
        @as(u32, st.wMinute),
        @as(u32, st.wSecond),
        @as(u32, st.wMilliseconds),
    }) catch "";
    var written: u32 = 0;
    _ = w32.WriteFile(handle, ts.ptr, @intCast(ts.len), &written, null);
    _ = w32.WriteFile(handle, msg.ptr, @intCast(msg.len), &written, null);
    const nl = "\r\n";
    _ = w32.WriteFile(handle, nl.ptr, @intCast(nl.len), &written, null);
}

fn debugLogWithText(prefix: []const u8, text: []const u8) void {
    var buf: [256]u8 = undefined;
    const display_len = @min(text.len, 200);
    const full = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, text[0..display_len] }) catch return;
    debugLog(full);
}

fn readClipboardWindows(out_buf: *[max_text_len]u8) ?[]const u8 {
    if (w32.OpenClipboard(null) == 0) return null;
    defer _ = w32.CloseClipboard();

    const handle = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return null;
    const wide_ptr = w32.GlobalLock(handle) orelse return null;
    defer _ = w32.GlobalUnlock(handle);

    var len: usize = 0;
    while (wide_ptr[len] != 0 and len < max_text_len) : (len += 1) {}

    var utf8_pos: usize = 0;
    for (0..len) |i| {
        const cp: u21 = wide_ptr[i];
        if (cp < 0x80) {
            if (utf8_pos >= max_text_len) break;
            out_buf[utf8_pos] = @intCast(cp);
            utf8_pos += 1;
        } else if (cp < 0x800) {
            if (utf8_pos + 2 > max_text_len) break;
            out_buf[utf8_pos] = @intCast(0xC0 | (cp >> 6));
            out_buf[utf8_pos + 1] = @intCast(0x80 | (cp & 0x3F));
            utf8_pos += 2;
        } else {
            if (utf8_pos + 3 > max_text_len) break;
            out_buf[utf8_pos] = @intCast(0xE0 | (cp >> 12));
            out_buf[utf8_pos + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            out_buf[utf8_pos + 2] = @intCast(0x80 | (cp & 0x3F));
            utf8_pos += 3;
        }
    }

    var trim_end = utf8_pos;
    while (trim_end > 0) {
        const c = out_buf[trim_end - 1];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            trim_end -= 1;
        } else break;
    }
    const result = out_buf[0..trim_end];
    if (result.len == 0) return null;
    return result;
}

fn writeClipboardWindows(text: []const u8) void {
    var wide_buf: [max_text_len + 1]u16 = undefined;
    var wide_len: usize = 0;
    for (text) |byte| {
        if (wide_len >= max_text_len) break;
        wide_buf[wide_len] = byte;
        wide_len += 1;
    }
    wide_buf[wide_len] = 0;

    const byte_size = (wide_len + 1) * 2;
    const hmem = w32.GlobalAlloc(w32.GMEM_MOVEABLE, byte_size) orelse return;
    const ptr = w32.GlobalLock(hmem) orelse {
        _ = w32.GlobalFree(hmem);
        return;
    };
    @memcpy(ptr[0 .. wide_len + 1], wide_buf[0 .. wide_len + 1]);
    _ = w32.GlobalUnlock(hmem);

    if (w32.OpenClipboard(null) == 0) {
        _ = w32.GlobalFree(hmem);
        return;
    }
    _ = w32.EmptyClipboard();
    _ = w32.SetClipboardData(w32.CF_UNICODETEXT, hmem);
    _ = w32.CloseClipboard();
}

fn htmlEscape(buf: []u8, pos: usize, text: []const u8) usize {
    var p = pos;
    for (text) |c| {
        if (p + 6 > buf.len) break;
        switch (c) {
            '<' => {
                @memcpy(buf[p .. p + 4], "&lt;");
                p += 4;
            },
            '>' => {
                @memcpy(buf[p .. p + 4], "&gt;");
                p += 4;
            },
            '&' => {
                @memcpy(buf[p .. p + 5], "&amp;");
                p += 5;
            },
            '"' => {
                @memcpy(buf[p .. p + 6], "&quot;");
                p += 6;
            },
            else => {
                buf[p] = c;
                p += 1;
            },
        }
    }
    return p;
}

pub fn writeHtmlToBuffer(buf: []u8, entries: []const Entry) usize {
    var pos: usize = 0;

    pos = appendStr(buf, pos,
        \\<!doctype html><html><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<style>
        \\:root{color-scheme:light dark}
        \\*{box-sizing:border-box;margin:0;padding:0}
        \\body{font-family:"Segoe UI",system-ui,sans-serif;background:#f8f9fb;color:#1a1a2e;padding:16px 16px 48px 16px;overflow-y:auto;font-size:16px;display:flex;flex-direction:column;min-height:100vh}
        \\h1{font-size:26px;font-weight:600;margin-bottom:2px}
        \\.sub{color:#6b7280;font-size:14px;margin-bottom:12px}
        \\#app-status{position:fixed;left:0;right:0;bottom:0;padding:10px 16px;background:#fff;border-top:1px solid #e5e7eb;font-size:13px;color:#374151;font-family:inherit}
        \\.navbar{display:flex;align-items:center;justify-content:center;gap:8px;margin-bottom:14px;flex-wrap:wrap}
        \\.navbar button{font-size:14px;padding:7px 14px;border:1px solid #d1d5db;border-radius:6px;cursor:pointer;background:#fff;color:#374151}
        \\.navbar button:hover{background:#f3f4f6}
        \\.navbar button.active{background:#3b82f6;color:#fff;border-color:#3b82f6}
        \\.navsep{width:1px;height:22px;background:#e5e7eb;margin:0 4px}
        \\#cal-root{flex:1;display:flex;flex-direction:column;min-height:0}
        \\.mtitle{font-size:20px;font-weight:600;margin-bottom:10px;text-align:center;flex:0 0 auto}
        \\.wrow{display:grid;grid-template-columns:repeat(7,minmax(150px,300px));gap:8px;margin-bottom:8px;justify-content:center;flex:1;min-height:0}
        \\.wrow.wk5{grid-template-columns:repeat(5,minmax(150px,300px))}
        \\.whdr{display:grid;grid-template-columns:repeat(7,minmax(150px,300px));gap:8px;margin-bottom:4px;justify-content:center;flex:0 0 auto}
        \\.whdr.wk5{grid-template-columns:repeat(5,minmax(150px,300px))}
        \\.whdr span{font-size:13px;font-weight:600;color:#6b7280;text-align:center;padding:2px}
        \\.whdr span:nth-child(6),.whdr span:nth-child(7){opacity:0.55}
        \\.dc{background:#fff;border:1px solid #e5e7eb;border-radius:6px;padding:10px;min-height:84px;width:auto;display:flex;flex-direction:column}
        \\.dc.today{border-color:#3b82f6;border-width:2px;box-shadow:0 0 0 2px rgba(59,130,246,0.1)}
        \\.dc.weekend{background:#f9fafb;opacity:0.7}
        \\.dc.weekend.today{opacity:1}
        \\.dc.empty{background:transparent;border:1px dashed #e5e7eb;opacity:0.3;min-height:40px}
        \\.dc.dayview{width:440px;min-height:200px}
        \\.dayview-wrap{display:flex;justify-content:center;margin-bottom:8px}
        \\.dh{display:flex;justify-content:space-between;align-items:center;margin-bottom:5px;padding-bottom:4px;border-bottom:1px solid #f3f4f6}
        \\.dn{font-weight:700;font-size:16px}
        \\.ents{flex:1;display:flex;flex-direction:column;gap:4px;overflow-y:auto}
        \\.ent{font-size:13px;padding:4px 6px;background:#f0f4ff;border-radius:4px;color:#1e40af;border:1px solid #dbeafe;display:flex;align-items:center;gap:6px;position:relative}
        \\.ent-text{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;cursor:default}
        \\.ent-del{cursor:pointer;color:#ef4444;font-size:20px;line-height:1;font-weight:700;opacity:0.6;flex-shrink:0;padding:2px 7px;border-radius:4px}
        \\.ent-del:hover{opacity:1;background:rgba(239,68,68,0.12)}
        \\.ent:hover .tooltip{display:block}
        \\.tooltip{display:none;position:absolute;left:0;top:100%;z-index:999;background:#1a1a2e;color:#fff;padding:6px 10px;border-radius:6px;font-size:13px;max-width:400px;word-break:break-all;white-space:normal;box-shadow:0 4px 12px rgba(0,0,0,0.2);pointer-events:none;margin-top:4px}
        \\.ne{font-size:12px;color:#d1d5db;font-style:italic}
        \\.cbtn{font-size:12px;padding:3px 8px;margin-top:4px;align-self:flex-end;border:1px solid #d1d5db;border-radius:4px;cursor:pointer;background:#fff;color:#374151}
        \\.cbtn:hover{background:#f3f4f6}
        \\.analytics-days{display:flex;flex-direction:column;gap:20px;max-width:700px;margin:0 auto}
        \\.aday-hdr{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:8px;padding-bottom:4px;border-bottom:2px solid #e5e7eb}
        \\.aday-title{font-size:16px;font-weight:700}
        \\.aday-total{font-size:13px;color:#6b7280}
        \\.analytics-list{display:flex;flex-direction:column;gap:8px}
        \\.arow{display:flex;align-items:center;gap:10px}
        \\.arow-label{position:relative;cursor:default;width:220px;flex-shrink:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px}
        \\.arow-label:hover .tooltip{display:block}
        \\.abar-track{flex:1;background:#f0f4ff;border-radius:4px;height:18px;overflow:hidden}
        \\.abar{background:#3b82f6;height:100%;border-radius:4px}
        \\.abar.ongoing{background:#f59e0b}
        \\.abar.filled{background:repeating-linear-gradient(45deg,#a78bfa,#a78bfa 6px,#c4b5fd 6px,#c4b5fd 12px)}
        \\.adur{width:90px;flex-shrink:0;text-align:right;font-size:13px;color:#6b7280}
        \\.atime{width:110px;flex-shrink:0;text-align:center;font-size:12px;color:#6b7280}
        \\.arow.filled .arow-label{font-style:italic;color:#7c3aed}
        \\.adur.filled{color:#7c3aed;font-style:italic}
        \\.abar.outside{background:#f97316}
        \\.arow.outside .arow-label{color:#c2410c}
        \\.adur.outside{color:#c2410c}
        \\.nav-right{margin-left:auto;display:flex;gap:6px}
        \\.modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,0.4);align-items:center;justify-content:center;z-index:1000}
        \\.modal-panel{background:#fff;border-radius:10px;padding:20px 24px;min-width:320px;box-shadow:0 10px 40px rgba(0,0,0,0.3)}
        \\.modal-panel h2{font-size:18px;margin-bottom:14px}
        \\.modal-row{display:flex;justify-content:space-between;align-items:center;gap:16px;margin-bottom:12px;font-size:14px}
        \\.modal-panel select,.modal-panel input[type=checkbox]{font-size:14px;padding:4px 6px;border:1px solid #d1d5db;border-radius:4px}
        \\.modal-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
        \\.modal-actions button{font-size:13px;padding:6px 14px;border:1px solid #d1d5db;border-radius:6px;cursor:pointer;background:#fff;color:#374151}
        \\.modal-actions button.primary{background:#3b82f6;color:#fff;border-color:#3b82f6}
        \\:root[data-theme="dark"] body{background:#0f1117;color:#e5e7eb}
        \\:root[data-theme="dark"] #app-status{background:#1a1d27;border-top-color:#2d3140;color:#e5e7eb}
        \\:root[data-theme="dark"] .navbar button{background:#1a1d27;color:#e5e7eb;border-color:#2d3140}
        \\:root[data-theme="dark"] .navbar button:hover{background:#2d3140}
        \\:root[data-theme="dark"] .navbar button.active{background:#3b82f6;color:#fff;border-color:#3b82f6}
        \\:root[data-theme="dark"] .navsep{background:#2d3140}
        \\:root[data-theme="dark"] .dc{background:#1a1d27;border-color:#2d3140}
        \\:root[data-theme="dark"] .dc.today{border-color:#3b82f6;box-shadow:0 0 0 2px rgba(59,130,246,0.15)}
        \\:root[data-theme="dark"] .dc.empty{background:transparent;border-color:#2d3140}
        \\:root[data-theme="dark"] .dh{border-bottom-color:#2d3140}
        \\:root[data-theme="dark"] .ent{background:#1e2433;border-color:#2d3748;color:#60a5fa}
        \\:root[data-theme="dark"] .ent:hover{background:#2d3748}
        \\:root[data-theme="dark"] .cbtn{background:#1a1d27;color:#e5e7eb;border-color:#2d3140}
        \\:root[data-theme="dark"] .cbtn:hover{background:#2d3140}
        \\:root[data-theme="dark"] .tooltip{background:#e5e7eb;color:#0f1117}
        \\:root[data-theme="dark"] .ne{color:#4b5563}
        \\:root[data-theme="dark"] .aday-hdr{border-bottom-color:#2d3140}
        \\:root[data-theme="dark"] .aday-total{color:#9ca3af}
        \\:root[data-theme="dark"] .abar-track{background:#1e2433}
        \\:root[data-theme="dark"] .adur{color:#9ca3af}
        \\:root[data-theme="dark"] .modal-panel{background:#1a1d27;color:#e5e7eb}
        \\:root[data-theme="dark"] .modal-panel input,:root[data-theme="dark"] .modal-panel select{background:#0f1117;color:#e5e7eb;border-color:#2d3140}
        \\</style>
        \\</head><body>
    );

    pos = appendStr(buf, pos,
        \\<h1>Work Log</h1>
        \\<p class="sub">Select text + <b>Ctrl+Alt+L</b> anywhere to store. Hover entries to see full text.</p>
    );

    pos = appendStr(buf, pos, "<div class=\"navbar\">");
    pos = appendStr(buf, pos, "<button onclick=\"navPrev()\">&larr; Prev</button>");
    pos = appendStr(buf, pos, "<button onclick=\"navToday()\">Today</button>");
    pos = appendStr(buf, pos, "<button onclick=\"navNext()\">Next &rarr;</button>");
    pos = appendStr(buf, pos, "<span class=\"navsep\"></span>");
    pos = appendStr(buf, pos, "<button id=\"vb-month\" onclick=\"setView('month')\" class=\"");
    if (view_mode == .month) pos = appendStr(buf, pos, "active");
    pos = appendStr(buf, pos, "\">Month</button>");
    pos = appendStr(buf, pos, "<button id=\"vb-week\" onclick=\"setView('week')\" class=\"");
    if (view_mode == .week) pos = appendStr(buf, pos, "active");
    pos = appendStr(buf, pos, "\">Week</button>");
    pos = appendStr(buf, pos, "<button id=\"vb-day\" onclick=\"setView('day')\" class=\"");
    if (view_mode == .day) pos = appendStr(buf, pos, "active");
    pos = appendStr(buf, pos, "\">Day</button>");
    pos = appendStr(buf, pos, "<span class=\"navsep\"></span>");
    pos = appendStr(buf, pos, "<button id=\"vb-analytics\" onclick=\"setView('analytics')\" class=\"");
    if (view_mode == .analytics) pos = appendStr(buf, pos, "active");
    pos = appendStr(buf, pos, "\">Analytics</button>");
    pos = appendStr(buf, pos, "<span class=\"navsep\"></span>");
    pos = appendStr(buf, pos, "<button id=\"vb-weekends\" onclick=\"toggleWeekends()\" class=\"");
    if (show_weekends) pos = appendStr(buf, pos, "active");
    pos = appendStr(buf, pos, "\">");
    pos = appendStr(buf, pos, if (show_weekends) "Hide Weekends" else "Show Weekends");
    pos = appendStr(buf, pos, "</button>");
    pos = appendStr(buf, pos, "<span class=\"nav-right\">");
    pos = appendStr(buf, pos, "<button onclick=\"openAbout()\" title=\"About\">&#8505;</button>");
    pos = appendStr(buf, pos, "<button onclick=\"openSettings()\" title=\"Settings\">&#9881;</button>");
    pos = appendStr(buf, pos, "</span>");
    pos = appendStr(buf, pos, "</div>");

    pos = appendStr(buf, pos, "<div id=\"cal-root\">");
    pos = writeViewBody(buf, pos, entries);
    pos = appendStr(buf, pos, "</div>");

    pos = appendStr(buf, pos,
        \\<div id="settings-overlay" class="modal-overlay">
        \\<div class="modal-panel">
        \\<h2>Settings</h2>
        \\<div class="modal-row"><label for="set-start">Work start hour</label><select id="set-start"></select></div>
        \\<div class="modal-row"><label for="set-end">Work end hour</label><select id="set-end"></select></div>
        \\<div class="modal-row"><label for="set-theme">Theme</label><select id="set-theme">
        \\<option value="auto">Auto (system)</option>
        \\<option value="light">Light</option>
        \\<option value="dark">Dark</option>
        \\</select></div>
        \\<div class="modal-row"><label for="set-fillgaps">Fill gaps in analytics</label><input type="checkbox" id="set-fillgaps"></div>
        \\<div class="modal-row"><label>Backup</label><button onclick="exportData()">Export CSV&hellip;</button></div>
        \\<div class="modal-actions">
        \\<button onclick="closeSettings()">Cancel</button>
        \\<button class="primary" onclick="saveSettingsForm()">Save</button>
        \\</div>
        \\</div>
        \\</div>
        \\<div id="about-overlay" class="modal-overlay">
        \\<div class="modal-panel">
        \\<h2>About Work Log</h2>
        \\<p class="sub" style="margin-bottom:10px">Work Log is a lightweight tool for keeping track of the tickets (or any text) you work on throughout the day, without breaking your flow to switch windows.</p>
        \\<p class="sub" style="margin-bottom:6px"><b>How it works:</b></p>
        \\<ul style="margin:0 0 10px 18px;font-size:13px;color:#6b7280;line-height:1.6">
        \\<li>Select any text (like a Jira ticket URL) in any application and press <b>Ctrl+Alt+L</b> to save it under today's date - no need to switch to this app first.</li>
        \\<li>Browse what you logged in the <b>Month</b>, <b>Week</b>, or <b>Day</b> view. Hover an entry to see its full text, and use the &times; to delete one.</li>
        \\<li><b>Analytics</b> shows how much time you spent on each ticket, based on the gap between when each one was logged.</li>
        \\<li>Use the gear icon to set your work hours, theme, fill-gaps behavior, and to export a CSV backup.</li>
        \\</ul>
        \\<p class="sub" style="margin-bottom:0">Version 0.2.0</p>
        \\<div class="modal-actions">
        \\<button class="primary" onclick="closeAbout()">Close</button>
        \\</div>
        \\</div>
        \\</div>
    );

    pos = appendStr(buf, pos, "<div id=\"app-status\">");
    pos = htmlEscape(buf, pos, currentStatus());
    pos = appendStr(buf, pos, "</div>");

    pos = appendStr(buf, pos,
        \\<script>
        \\async function copyDay(date){
        \\  try{
        \\    if(window.zero&&window.zero.commands){
        \\      await window.zero.commands.invoke("app.copy-day-"+date);
        \\    }
        \\  }catch(e){console.error(e)}
        \\}
        \\async function delEntry(date,idx){
        \\  try{
        \\    if(window.zero&&window.zero.commands){
        \\      await window.zero.commands.invoke("app.delete-"+date+"-idx-"+idx);
        \\    }
        \\  }catch(e){console.error(e)}
        \\  refreshCalendar();
        \\}
        \\let lastCalHtml = document.getElementById("cal-root").innerHTML;
        \\let lastStatus = document.getElementById("app-status").textContent;
    );

    pos = appendStr(buf, pos, "let currentThemeSetting = \"");
    pos = appendStr(buf, pos, switch (app_theme) {
        .auto => "auto",
        .light => "light",
        .dark => "dark",
    });
    pos = appendStr(buf, pos, "\";\napplyTheme(currentThemeSetting);\n");
    pos = appendStr(buf, pos, "let weekendsShown = ");
    pos = appendStr(buf, pos, if (show_weekends) "true" else "false");
    pos = appendStr(buf, pos, ";\n");

    pos = appendStr(buf, pos,
        \\function applyResult(r){
        \\  if(r && typeof r.html === "string" && r.html !== lastCalHtml){
        \\    lastCalHtml = r.html;
        \\    document.getElementById("cal-root").innerHTML = r.html;
        \\  }
        \\  if(r && typeof r.status === "string" && r.status !== lastStatus){
        \\    lastStatus = r.status;
        \\    document.getElementById("app-status").textContent = r.status;
        \\  }
        \\}
        \\async function refreshCalendar(){
        \\  try{
        \\    if(window.zero&&window.zero.invoke){
        \\      const r = await window.zero.invoke("app.get-calendar", {});
        \\      applyResult(r);
        \\    }
        \\  }catch(e){console.error(e)}
        \\}
        \\function setActiveViewButton(mode){
        \\  ["month","week","day","analytics"].forEach(function(m){
        \\    const el = document.getElementById("vb-"+m);
        \\    if(el){ el.classList.toggle("active", m === mode); }
        \\  });
        \\}
        \\async function callNav(cmd){
        \\  try{
        \\    if(window.zero&&window.zero.invoke){
        \\      const r = await window.zero.invoke(cmd, {});
        \\      applyResult(r);
        \\    }
        \\  }catch(e){console.error(e)}
        \\}
        \\async function toggleWeekends(){
        \\  await callNav("app.toggle-weekends");
        \\  weekendsShown = !weekendsShown;
        \\  const el = document.getElementById("vb-weekends");
        \\  if(el){
        \\    el.classList.toggle("active", weekendsShown);
        \\    el.textContent = weekendsShown ? "Hide Weekends" : "Show Weekends";
        \\  }
        \\}
        \\async function navPrev(){ await callNav("app.nav-prev"); }
        \\async function navNext(){ await callNav("app.nav-next"); }
        \\async function navToday(){ await callNav("app.nav-today"); }
        \\async function setView(mode){
        \\  setActiveViewButton(mode);
        \\  await callNav("app.set-view-"+mode);
        \\}
        \\function applyTheme(mode){
        \\  currentThemeSetting = mode;
        \\  let effective = mode;
        \\  if(mode === "auto"){
        \\    effective = (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) ? "dark" : "light";
        \\  }
        \\  document.documentElement.setAttribute("data-theme", effective);
        \\}
        \\if(window.matchMedia){
        \\  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function(){
        \\    if(currentThemeSetting === "auto") applyTheme("auto");
        \\  });
        \\}
        \\function populateHourSelect(id, selected){
        \\  const el = document.getElementById(id);
        \\  el.innerHTML = "";
        \\  for(let h=0; h<24; h++){
        \\    const opt = document.createElement("option");
        \\    opt.value = h;
        \\    opt.textContent = (h<10?"0":"")+h+":00";
        \\    if(h === selected) opt.selected = true;
        \\    el.appendChild(opt);
        \\  }
        \\}
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
        \\function closeSettings(){
        \\  document.getElementById("settings-overlay").style.display = "none";
        \\}
        \\function openAbout(){
        \\  document.getElementById("about-overlay").style.display = "flex";
        \\}
        \\function closeAbout(){
        \\  document.getElementById("about-overlay").style.display = "none";
        \\}
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
        \\async function exportData(){
        \\  try{
        \\    if(!(window.zero&&window.zero.invoke)) return;
        \\    const dlg = await window.zero.invoke("native-sdk.dialog.saveFile", {
        \\      title: "Export Work Log Backup",
        \\      defaultName: "work-log-backup.csv"
        \\    });
        \\    const path = (typeof dlg === "string") ? dlg : (dlg && dlg.path);
        \\    if(!path) return;
        \\    const r = await window.zero.invoke("app.export-data", { path: path });
        \\    if(r && r.ok){
        \\      alert("Backup exported to:\n" + path);
        \\    } else {
        \\      alert("Export failed. Check the destination and try again.");
        \\    }
        \\  }catch(e){
        \\    console.error(e);
        \\    alert("Export failed: " + (e && e.message ? e.message : e));
        \\  }
        \\}
        \\setInterval(refreshCalendar, 2000);
        \\</script>
        \\</body></html>
    );

    return pos;
}

fn writeViewBody(buf: []u8, pos_start: usize, entries: []const Entry) usize {
    return switch (view_mode) {
        .month => writeMonthBody(buf, pos_start, entries),
        .week => writeWeekBody(buf, pos_start, entries),
        .day => writeDayBody(buf, pos_start, entries),
        .analytics => writeAnalyticsBody(buf, pos_start, entries),
    };
}

fn writeDayCell(buf: []u8, pos_start: usize, entries: []const Entry, year: u16, month: u16, day: u16, dow: u16, today: *const [10]u8) usize {
    var pos = pos_start;
    const date = formatDate(year, month, day);
    const is_today = std.mem.eql(u8, &date, today);
    pos = appendStr(buf, pos, "<div class=\"dc");
    if (dow >= 5) pos = appendStr(buf, pos, " weekend");
    if (is_today) pos = appendStr(buf, pos, " today");
    pos = appendStr(buf, pos, "\"><div class=\"dh\"><span class=\"dn\">");
    pos = appendNum(buf, pos, day);
    pos = appendStr(buf, pos, "</span><span>");
    pos = appendStr(buf, pos, day_names[dow]);
    pos = appendStr(buf, pos, "</span></div><div class=\"ents\">");

    var count: u32 = 0;
    for (entries) |entry| {
        if (std.mem.eql(u8, &entry.date, &date)) {
            const text = entry.text_buf[0..entry.text_len];
            pos = appendStr(buf, pos, "<div class=\"ent\"><span class=\"ent-text\">");
            const trim_len = 15;
            if (text.len > trim_len) {
                pos = appendStr(buf, pos, "...");
                pos = htmlEscape(buf, pos, text[text.len - trim_len ..]);
            } else {
                pos = htmlEscape(buf, pos, text);
            }
            pos = appendStr(buf, pos, "</span><span class=\"ent-del\" onclick=\"delEntry('");
            pos = appendStr(buf, pos, &date);
            pos = appendStr(buf, pos, "',");
            pos = appendNum(buf, pos, @intCast(count));
            pos = appendStr(buf, pos, ")\">&times;</span><div class=\"tooltip\">");
            pos = htmlEscape(buf, pos, text);
            pos = appendStr(buf, pos, "</div></div>");
            count += 1;
        }
    }
    if (count == 0) {
        pos = appendStr(buf, pos, "<span class=\"ne\">No entries</span>");
    }

    pos = appendStr(buf, pos, "</div>");
    if (count > 0) {
        pos = appendStr(buf, pos, "<button class=\"cbtn\" onclick=\"copyDay('");
        pos = appendStr(buf, pos, &date);
        pos = appendStr(buf, pos, "')\">Copy all</button>");
    }
    pos = appendStr(buf, pos, "</div>");
    return pos;
}

fn writeMonthBody(buf: []u8, pos_start: usize, entries: []const Entry) usize {
    const today = todayDateStr();
    const dim = daysInMonth(view_year, view_month);
    var pos = pos_start;

    pos = appendStr(buf, pos, "<div class=\"mtitle\">");
    if (view_month >= 1 and view_month <= 12) {
        pos = appendStr(buf, pos, month_names[view_month - 1]);
    }
    pos = appendStr(buf, pos, " ");
    pos = appendNum(buf, pos, view_year);
    pos = appendStr(buf, pos, "</div>");

    const cols: u16 = if (show_weekends) 7 else 5;
    pos = appendStr(buf, pos, if (show_weekends)
        "<div class=\"whdr\"><span>Mon</span><span>Tue</span><span>Wed</span><span>Thu</span><span>Fri</span><span>Sat</span><span>Sun</span></div>"
    else
        "<div class=\"whdr wk5\"><span>Mon</span><span>Tue</span><span>Wed</span><span>Thu</span><span>Fri</span></div>");

    const first_dow = dayOfWeek(view_year, view_month, 1);
    const wrow_class = if (show_weekends) "<div class=\"wrow\">" else "<div class=\"wrow wk5\">";

    var day_num: u16 = 1;
    var in_row: bool = false;
    var col: u16 = 0;

    if (first_dow > 0 and (show_weekends or first_dow < 5)) {
        pos = appendStr(buf, pos, wrow_class);
        in_row = true;
        var blank: u16 = 0;
        while (blank < first_dow) : (blank += 1) {
            pos = appendStr(buf, pos, "<div class=\"dc empty\"></div>");
            col += 1;
        }
    }

    while (day_num <= dim) {
        const dow = dayOfWeek(view_year, view_month, day_num);

        if (!show_weekends and dow >= 5) {
            day_num += 1;
            continue;
        }

        if (!in_row) {
            pos = appendStr(buf, pos, wrow_class);
            in_row = true;
            col = 0;
            var fill: u16 = 0;
            while (fill < dow) : (fill += 1) {
                pos = appendStr(buf, pos, "<div class=\"dc empty\"></div>");
                col += 1;
            }
        }

        pos = writeDayCell(buf, pos, entries, view_year, view_month, day_num, dow, &today);

        col += 1;
        day_num += 1;

        if (col >= cols) {
            pos = appendStr(buf, pos, "</div>");
            in_row = false;
            col = 0;
        }
    }

    if (in_row and col > 0) {
        while (col < cols) : (col += 1) {
            pos = appendStr(buf, pos, "<div class=\"dc empty\"></div>");
        }
        pos = appendStr(buf, pos, "</div>");
    }

    return pos;
}

fn writeWeekBody(buf: []u8, pos_start: usize, entries: []const Entry) usize {
    const today = todayDateStr();
    var pos = pos_start;

    const dow = dayOfWeek(view_year, view_month, view_day);
    const monday = addDays(view_year, view_month, view_day, -@as(i64, dow));
    const week_days: u16 = if (show_weekends) 7 else 5;
    const end_day = addDays(monday.year, monday.month, monday.day, week_days - 1);

    pos = appendStr(buf, pos, "<div class=\"mtitle\">");
    pos = appendStr(buf, pos, month_names[monday.month - 1]);
    pos = appendStr(buf, pos, " ");
    pos = appendNum(buf, pos, monday.day);
    pos = appendStr(buf, pos, " - ");
    if (end_day.month != monday.month) {
        pos = appendStr(buf, pos, month_names[end_day.month - 1]);
        pos = appendStr(buf, pos, " ");
    }
    pos = appendNum(buf, pos, end_day.day);
    pos = appendStr(buf, pos, ", ");
    pos = appendNum(buf, pos, end_day.year);
    pos = appendStr(buf, pos, "</div>");

    pos = appendStr(buf, pos, if (show_weekends)
        "<div class=\"whdr\"><span>Mon</span><span>Tue</span><span>Wed</span><span>Thu</span><span>Fri</span><span>Sat</span><span>Sun</span></div>"
    else
        "<div class=\"whdr wk5\"><span>Mon</span><span>Tue</span><span>Wed</span><span>Thu</span><span>Fri</span></div>");
    pos = appendStr(buf, pos, if (show_weekends) "<div class=\"wrow\">" else "<div class=\"wrow wk5\">");

    var i: u16 = 0;
    while (i < week_days) : (i += 1) {
        const c = addDays(monday.year, monday.month, monday.day, i);
        pos = writeDayCell(buf, pos, entries, c.year, c.month, c.day, i, &today);
    }

    pos = appendStr(buf, pos, "</div>");
    return pos;
}

const weekday_names_full = [7][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };

fn writeDayBody(buf: []u8, pos_start: usize, entries: []const Entry) usize {
    var pos = pos_start;
    const dow = dayOfWeek(view_year, view_month, view_day);
    const date = formatDate(view_year, view_month, view_day);

    pos = appendStr(buf, pos, "<div class=\"mtitle\">");
    pos = appendStr(buf, pos, weekday_names_full[dow]);
    pos = appendStr(buf, pos, ", ");
    pos = appendStr(buf, pos, month_names[view_month - 1]);
    pos = appendStr(buf, pos, " ");
    pos = appendNum(buf, pos, view_day);
    pos = appendStr(buf, pos, ", ");
    pos = appendNum(buf, pos, view_year);
    pos = appendStr(buf, pos, "</div>");

    pos = appendStr(buf, pos, "<div class=\"dayview-wrap\"><div class=\"dc dayview\"><div class=\"ents\">");

    var count: u32 = 0;
    for (entries) |entry| {
        if (std.mem.eql(u8, &entry.date, &date)) {
            const text = entry.text_buf[0..entry.text_len];
            pos = appendStr(buf, pos, "<div class=\"ent\"><span class=\"ent-text\">");
            const trim_len = 15;
            if (text.len > trim_len) {
                pos = appendStr(buf, pos, "...");
                pos = htmlEscape(buf, pos, text[text.len - trim_len ..]);
            } else {
                pos = htmlEscape(buf, pos, text);
            }
            pos = appendStr(buf, pos, "</span><span class=\"ent-del\" onclick=\"delEntry('");
            pos = appendStr(buf, pos, &date);
            pos = appendStr(buf, pos, "',");
            pos = appendNum(buf, pos, @intCast(count));
            pos = appendStr(buf, pos, ")\">&times;</span><div class=\"tooltip\">");
            pos = htmlEscape(buf, pos, text);
            pos = appendStr(buf, pos, "</div></div>");
            count += 1;
        }
    }
    if (count == 0) {
        pos = appendStr(buf, pos, "<span class=\"ne\">No entries</span>");
    }
    pos = appendStr(buf, pos, "</div>");
    if (count > 0) {
        pos = appendStr(buf, pos, "<button class=\"cbtn\" onclick=\"copyDay('");
        pos = appendStr(buf, pos, &date);
        pos = appendStr(buf, pos, "')\">Copy all</button>");
    }
    pos = appendStr(buf, pos, "</div></div>");

    return pos;
}

fn writeDuration(buf: []u8, pos_start: usize, seconds_in: i64) usize {
    var pos = pos_start;
    const seconds: i64 = if (seconds_in < 0) 0 else seconds_in;
    const days = @divFloor(seconds, 86400);
    const hours = @divFloor(@mod(seconds, 86400), 3600);
    const mins = @divFloor(@mod(seconds, 3600), 60);

    if (days > 0) {
        pos = appendNum(buf, pos, @intCast(days));
        pos = appendStr(buf, pos, "d ");
        pos = appendNum(buf, pos, @intCast(hours));
        pos = appendStr(buf, pos, "h");
    } else if (hours > 0) {
        pos = appendNum(buf, pos, @intCast(hours));
        pos = appendStr(buf, pos, "h ");
        pos = appendNum(buf, pos, @intCast(mins));
        pos = appendStr(buf, pos, "m");
    } else if (mins > 0) {
        pos = appendNum(buf, pos, @intCast(mins));
        pos = appendStr(buf, pos, "m");
    } else {
        pos = appendStr(buf, pos, "<1m");
    }
    return pos;
}

fn dayBoundaryTimestamp(year: u16, month: u16, day: u16, hour: u8) i64 {
    return daysFromCivil(year, month, day) * 86400 + @as(i64, hour) * 3600;
}

const RowStyle = enum { normal, filled, outside };

fn hourOfDay(timestamp: i64) u8 {
    return @intCast(@divFloor(@mod(timestamp, 86400), 3600));
}

fn isOutsideWorkHours(timestamp: i64) bool {
    const hour = hourOfDay(timestamp);
    return hour < work_start_hour or hour >= work_end_hour;
}

/// A ticket started outside configured work hours is shown as a flat 1h
/// block in a distinct color - actual gap-to-next-entry math would either
/// be misleadingly large or run into the next day, so it's not attempted.
/// Otherwise, duration bridges to the next entry logged that day, or - for
/// the day's last entry - the configured end-of-workday boundary (clamped
/// at 0), so it fills automatically without waiting for the workday to end.
fn groupEntryDuration(group: []const Entry, gi: usize, entry: Entry, pd: DateParts) struct { dur: i64, style: RowStyle } {
    if (isOutsideWorkHours(entry.timestamp)) {
        return .{ .dur = 3600, .style = .outside };
    }
    if (gi + 1 < group.len) {
        return .{ .dur = group[gi + 1].timestamp - entry.timestamp, .style = .normal };
    }
    const end_ts = dayBoundaryTimestamp(pd.year, pd.month, pd.day, work_end_hour);
    return .{ .dur = @max(0, end_ts - entry.timestamp), .style = .normal };
}

fn writeClockTime(buf: []u8, pos_start: usize, timestamp: i64) usize {
    var pos = pos_start;
    const secs_in_day = @mod(timestamp, 86400);
    const hour = @divFloor(secs_in_day, 3600);
    const minute = @divFloor(@mod(secs_in_day, 3600), 60);
    if (hour < 10) pos = appendStr(buf, pos, "0");
    pos = appendNum(buf, pos, @intCast(hour));
    pos = appendStr(buf, pos, ":");
    if (minute < 10) pos = appendStr(buf, pos, "0");
    pos = appendNum(buf, pos, @intCast(minute));
    return pos;
}

fn writeAnalyticsRow(buf: []u8, pos_start: usize, text: []const u8, start_ts: i64, dur: i64, max_dur: i64, style: RowStyle) usize {
    var pos = pos_start;
    const style_class: []const u8 = switch (style) {
        .normal => "",
        .filled => " filled",
        .outside => " outside",
    };

    pos = appendStr(buf, pos, "<div class=\"arow");
    pos = appendStr(buf, pos, style_class);
    pos = appendStr(buf, pos, "\">");
    pos = appendStr(buf, pos, "<div class=\"arow-label\">");
    const trim_len = 15;
    if (text.len > trim_len) {
        pos = appendStr(buf, pos, "...");
        pos = htmlEscape(buf, pos, text[text.len - trim_len ..]);
    } else {
        pos = htmlEscape(buf, pos, text);
    }
    pos = appendStr(buf, pos, "<div class=\"tooltip\">");
    pos = htmlEscape(buf, pos, text);
    pos = appendStr(buf, pos, "</div></div>");

    pos = appendStr(buf, pos, "<div class=\"atime\">");
    pos = writeClockTime(buf, pos, start_ts);
    pos = appendStr(buf, pos, " - ");
    pos = writeClockTime(buf, pos, start_ts + dur);
    pos = appendStr(buf, pos, "</div>");

    const pct: u16 = @intCast(@min(@as(i64, 100), @max(@as(i64, 0), @divFloor(dur * 100, max_dur))));
    pos = appendStr(buf, pos, "<div class=\"abar-track\"><div class=\"abar");
    pos = appendStr(buf, pos, style_class);
    pos = appendStr(buf, pos, "\" style=\"width:");
    pos = appendNum(buf, pos, pct);
    pos = appendStr(buf, pos, "%\"></div></div>");

    pos = appendStr(buf, pos, "<div class=\"adur");
    pos = appendStr(buf, pos, style_class);
    pos = appendStr(buf, pos, "\">");
    pos = writeDuration(buf, pos, dur);
    switch (style) {
        .filled => pos = appendStr(buf, pos, " (filled)"),
        .outside => pos = appendStr(buf, pos, " (outside hours)"),
        .normal => {},
    }
    pos = appendStr(buf, pos, "</div></div>");
    return pos;
}

/// Groups entries by date (assumes entries are already in chronological
/// append order, so same-date entries are contiguous) and walks the groups
/// most-recent-day-first. When "fill gaps" is on and a day's first entry
/// starts more than an hour into the workday, a synthetic leading row
/// carries over the last ticket worked before this day - shown in a
/// visually distinct "filled" style since it's inferred, not measured.
fn writeAnalyticsBody(buf: []u8, pos_start: usize, entries: []const Entry) usize {
    var pos = pos_start;
    pos = appendStr(buf, pos, "<div class=\"mtitle\">Time per Ticket</div>");

    if (entries.len == 0) {
        pos = appendStr(buf, pos, "<p class=\"sub\" style=\"text-align:center\">No entries yet.</p>");
        return pos;
    }

    pos = appendStr(buf, pos, "<div class=\"analytics-days\">");

    var end: usize = entries.len;
    while (end > 0) {
        const date = entries[end - 1].date;
        var start = end;
        while (start > 0 and std.mem.eql(u8, &entries[start - 1].date, &date)) : (start -= 1) {}
        const group = entries[start..end];
        const pd = parseDateStr(&date);

        var fill_start_ts: i64 = 0;
        var fill_dur: i64 = 0;
        var fill_text: []const u8 = "";
        var has_fill = false;
        if (fill_gaps and start > 0) {
            const day_start_ts = dayBoundaryTimestamp(pd.year, pd.month, pd.day, work_start_hour);
            const gap = group[0].timestamp - day_start_ts;
            if (gap > 3600) {
                const prev = entries[start - 1];
                fill_text = prev.text_buf[0..prev.text_len];
                fill_start_ts = day_start_ts;
                fill_dur = gap;
                has_fill = true;
            }
        }

        var day_total: i64 = if (has_fill) fill_dur else 0;
        var max_dur: i64 = if (has_fill) fill_dur else 1;
        for (group, 0..) |entry, gi| {
            const gd = groupEntryDuration(group, gi, entry, pd);
            day_total += gd.dur;
            if (gd.dur > max_dur) max_dur = gd.dur;
        }
        if (max_dur < 1) max_dur = 1;

        const dow = dayOfWeek(pd.year, pd.month, pd.day);

        pos = appendStr(buf, pos, "<div class=\"aday\"><div class=\"aday-hdr\"><span class=\"aday-title\">");
        pos = appendStr(buf, pos, weekday_names_full[dow]);
        pos = appendStr(buf, pos, ", ");
        pos = appendStr(buf, pos, month_names[pd.month - 1]);
        pos = appendStr(buf, pos, " ");
        pos = appendNum(buf, pos, pd.day);
        pos = appendStr(buf, pos, ", ");
        pos = appendNum(buf, pos, pd.year);
        pos = appendStr(buf, pos, "</span><span class=\"aday-total\">Total: ");
        pos = writeDuration(buf, pos, day_total);
        pos = appendStr(buf, pos, "</span></div><div class=\"analytics-list\">");

        if (has_fill) {
            pos = writeAnalyticsRow(buf, pos, fill_text, fill_start_ts, fill_dur, max_dur, .filled);
        }

        for (group, 0..) |entry, gi| {
            const gd = groupEntryDuration(group, gi, entry, pd);
            const text = entry.text_buf[0..entry.text_len];
            pos = writeAnalyticsRow(buf, pos, text, entry.timestamp, gd.dur, max_dur, gd.style);
        }

        pos = appendStr(buf, pos, "</div></div>");
        end = start;
    }

    pos = appendStr(buf, pos, "</div>");

    return pos;
}

/// Minimal, controlled JSON field readers for the small settings payload
/// this app generates itself client-side - not a general-purpose parser.
fn jsonFieldStart(payload: []const u8, field: []const u8) ?usize {
    var pattern_buf: [40]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{field}) catch return null;
    const idx = std.mem.indexOf(u8, payload, pattern) orelse return null;
    var i = idx + pattern.len;
    while (i < payload.len and payload[i] == ' ') : (i += 1) {}
    return i;
}

fn jsonUnsignedField(payload: []const u8, field: []const u8) ?u8 {
    const start = jsonFieldStart(payload, field) orelse return null;
    var i = start;
    while (i < payload.len and std.ascii.isDigit(payload[i])) : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseUnsigned(u8, payload[start..i], 10) catch null;
}

fn jsonBoolField(payload: []const u8, field: []const u8) ?bool {
    const start = jsonFieldStart(payload, field) orelse return null;
    if (std.mem.startsWith(u8, payload[start..], "true")) return true;
    if (std.mem.startsWith(u8, payload[start..], "false")) return false;
    return null;
}

/// Unescapes JSON string content (notably `\\` -> `\`), since JS's
/// JSON.stringify doubles backslashes - a Windows path like
/// "C:\Users\..." arrives here as "C:\\\\Users\\\\..." and must be
/// unescaped before use, not copied verbatim.
fn jsonStringField(payload: []const u8, field: []const u8, out: []u8) ?[]const u8 {
    const start = jsonFieldStart(payload, field) orelse return null;
    if (start >= payload.len or payload[start] != '"') return null;
    var i = start + 1;
    var out_pos: usize = 0;
    while (i < payload.len and payload[i] != '"' and out_pos < out.len) {
        if (payload[i] == '\\' and i + 1 < payload.len) {
            const esc = payload[i + 1];
            out[out_pos] = switch (esc) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '/' => '/',
                else => esc,
            };
            out_pos += 1;
            i += 2;
        } else {
            out[out_pos] = payload[i];
            out_pos += 1;
            i += 1;
        }
    }
    if (i >= payload.len or payload[i] != '"') return null;
    return out[0..out_pos];
}

fn appendStr(buf: []u8, pos: usize, s: []const u8) usize {
    const len = @min(s.len, buf.len -| pos);
    if (len > 0) @memcpy(buf[pos .. pos + len], s[0..len]);
    return pos + len;
}

fn appendNum(buf: []u8, pos: usize, n: u16) usize {
    var tmp: [5]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return pos;
    return appendStr(buf, pos, s);
}

pub fn main(init: std.process.Init) !void {
    initLogPath();
    debugLog("=== Work Log starting ===");
    resetViewToToday();
    setStatus("Ready. Select text + Ctrl+Alt+L to store.");
    var app_state = WorkLogApp{};
    app_state.initDataPath();
    debugLogWithText("data path: ", app_state.dataPath());
    app_state.loadSettings();
    app_state.loadFromFile();
    debugLog("loaded entries from file");
    app_state.rebuildHtml();
    debugLog("initial HTML built");

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "work-log",
        .window_title = "Work Log",
        .bundle_id = "dev.native_sdk.work_log",
        .icon_path = "assets/icon.svg",
        .default_frame = native_sdk.geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = true,
        .bridge = app_state.bridge(),
        .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
        .js_window_api = true,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{
                .allowed_origins = &bridge_origins,
                .external_links = .{
                    .action = .open_system_browser,
                    .allowed_urls = &.{"https://*"},
                },
            },
        },
    }, init);
}

test "today date string format" {
    const date = todayDateStr();
    try std.testing.expect(date[4] == '-');
    try std.testing.expect(date[7] == '-');
}

test "html generation" {
    var buf: [64 * 1024]u8 = undefined;
    const entries = [_]Entry{};
    const len = writeHtmlToBuffer(&buf, &entries);
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "Work Log") != null);
}

test "addDays across month and leap-year boundaries" {
    const a = addDays(2026, 2, 28, 1);
    try std.testing.expectEqual(@as(u16, 2026), a.year);
    try std.testing.expectEqual(@as(u16, 3), a.month);
    try std.testing.expectEqual(@as(u16, 1), a.day);

    const b = addDays(2024, 2, 28, 1);
    try std.testing.expectEqual(@as(u16, 2024), b.year);
    try std.testing.expectEqual(@as(u16, 2), b.month);
    try std.testing.expectEqual(@as(u16, 29), b.day);

    const c = addDays(2025, 12, 31, 1);
    try std.testing.expectEqual(@as(u16, 2026), c.year);
    try std.testing.expectEqual(@as(u16, 1), c.month);
    try std.testing.expectEqual(@as(u16, 1), c.day);

    const d = addDays(2026, 1, 1, -1);
    try std.testing.expectEqual(@as(u16, 2025), d.year);
    try std.testing.expectEqual(@as(u16, 12), d.month);
    try std.testing.expectEqual(@as(u16, 31), d.day);
}

test "days-from-civil round trip" {
    const z = daysFromCivil(2026, 7, 10);
    const back = civilFromDays(z);
    try std.testing.expectEqual(@as(i32, 2026), back.year);
    try std.testing.expectEqual(@as(u16, 7), back.month);
    try std.testing.expectEqual(@as(u16, 10), back.day);
}

test "known weekday reference" {
    // 2024-01-01 was a Monday.
    try std.testing.expectEqual(@as(u16, 0), dayOfWeek(2024, 1, 1));
}

test "duration formatting" {
    var buf: [64]u8 = undefined;

    var len = writeDuration(&buf, 0, 45);
    try std.testing.expect(std.mem.eql(u8, buf[0..len], "<1m"));

    len = writeDuration(&buf, 0, 125);
    try std.testing.expect(std.mem.eql(u8, buf[0..len], "2m"));

    len = writeDuration(&buf, 0, 3900);
    try std.testing.expect(std.mem.eql(u8, buf[0..len], "1h 5m"));

    len = writeDuration(&buf, 0, 90000);
    try std.testing.expect(std.mem.eql(u8, buf[0..len], "1d 1h"));
}

test "analytics body renders without entries" {
    var buf: [8 * 1024]u8 = undefined;
    const entries = [_]Entry{};
    const len = writeAnalyticsBody(&buf, 0, &entries);
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "No entries yet") != null);
}
