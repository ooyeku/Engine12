const std = @import("std");
const Response = @import("../http/response.zig").Response;
const manager_mod = @import("manager.zig");

var hot_reload_manager_for_injector: ?*manager_mod.HotReloadManager = null;
var hot_reload_manager_mutex: std.Thread.Mutex = .{};

pub fn setHotReloadManager(manager: ?*manager_mod.HotReloadManager) void {
    hot_reload_manager_mutex.lock();
    defer hot_reload_manager_mutex.unlock();
    hot_reload_manager_for_injector = manager;
}

fn getHotReloadManager() ?*manager_mod.HotReloadManager {
    hot_reload_manager_mutex.lock();
    defer hot_reload_manager_mutex.unlock();
    return hot_reload_manager_for_injector;
}

const HOT_RELOAD_SCRIPT =
    \\    <script>
    \\        // Hot reload WebSocket connection (development mode only)
    \\        (function() {
    \\            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    \\            const wsUrl = protocol + '//' + window.location.hostname + ':9000/ws/hot-reload';
    \\            let ws = null;
    \\            let reconnectTimeout = null;
    \\            
    \\            function connect() {
    \\                try {
    \\                    ws = new WebSocket(wsUrl);
    \\                    
    \\                    ws.onopen = function() {
    \\                        console.log('[HotReload] Connected to hot reload server');
    \\                        if (reconnectTimeout) {
    \\                            clearTimeout(reconnectTimeout);
    \\                            reconnectTimeout = null;
    \\                        }
    \\                    };
    \\                    
    \\                    ws.onmessage = function(event) {
    \\                        try {
    \\                            const message = JSON.parse(event.data);
    \\                            if (message.type === 'reload') {
    \\                                console.log('[HotReload] File changed:', message.file);
    \\                                console.log('[HotReload] Reloading page...');
    \\                                window.location.reload();
    \\                            }
    \\                        } catch (e) {
    \\                            console.error('[HotReload] Error parsing message:', e);
    \\                        }
    \\                    };
    \\                    
    \\                    ws.onerror = function(error) {
    \\                        console.error('[HotReload] WebSocket error:', error);
    \\                    };
    \\                    
    \\                    ws.onclose = function() {
    \\                        console.log('[HotReload] Connection closed, reconnecting in 2 seconds...');
    \\                        ws = null;
    \\                        reconnectTimeout = setTimeout(connect, 2000);
    \\                    };
    \\                } catch (e) {
    \\                    console.error('[HotReload] Error connecting:', e);
    \\                    reconnectTimeout = setTimeout(connect, 2000);
    \\                }
    \\            }
    \\            
    \\            connect();
    \\        })();
    \\    </script>
;

pub fn injectHotReloadScript(resp: Response) Response {
    const manager = getHotReloadManager() orelse return resp;
    if (!manager.enabled) return resp;

    const body = resp.getBody();
    if (body.len == 0) return resp;

    const is_html = body[0] == '<' or std.mem.indexOf(u8, body, "<html") != null or std.mem.indexOf(u8, body, "<!DOCTYPE") != null;
    if (!is_html) return resp;

    if (std.mem.indexOf(u8, body, "[HotReload]") != null) return resp;

    const body_end_pos = std.mem.lastIndexOf(u8, body, "</body>") orelse return resp;

    const persistent_allocator = std.heap.page_allocator;
    const new_body = persistent_allocator.alloc(u8, body.len + HOT_RELOAD_SCRIPT.len) catch return resp;
    @memcpy(new_body[0..body_end_pos], body[0..body_end_pos]);
    @memcpy(new_body[body_end_pos..][0..HOT_RELOAD_SCRIPT.len], HOT_RELOAD_SCRIPT);
    @memcpy(new_body[body_end_pos + HOT_RELOAD_SCRIPT.len ..], body[body_end_pos..]);

    return Response.html(new_body);
}
