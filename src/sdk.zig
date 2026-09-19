//! Zig adapter for the official Cursor SDK Bridge.
//!
//! Cursor does not publish a C ABI or a native library. `cursor-sdk-bridge` is a
//! Bun-compiled Mach-O *executable* (`MH_EXECUTE`) whose only exported symbol is
//! `__mh_execute_header`. The supported interface for Zig (and Go/Rust/Java) is
//! spawning that process and speaking `sdk.v1` Connect over HTTP/1.1 JSON:
//!
//!   POST http://<loopback>/sdk.v1.<Service>/<Method>
//!
//! That Connect JSON surface *is* the ABI. This module is the Zig library that
//! wraps it — not a clone of `@cursor/sdk` internals, which are unpublished.
//!
//! Official docs: https://cursor.com/docs/sdk/bridge
//! Contract:     https://github.com/cursor/sdk-bridge

const bridge_mod = @import("bridge.zig");
const toolcb_mod = @import("toolcb.zig");

pub const protocol_version = "sdk.v1";
pub const transport = "connect-http1-json";
pub const has_c_abi = false;

pub const Bridge = bridge_mod.Bridge;
pub const spawn = bridge_mod.spawn;
pub const findBridgeBinary = bridge_mod.findBridgeBinary;
pub const Hub = toolcb_mod.Hub;
pub const Waiter = toolcb_mod.Waiter;

pub const Service = struct {
    pub const agent = "sdk.v1.SdkAgentService";
    pub const cursor = "sdk.v1.SdkCursorService";
    pub const control = "sdk.v1.SdkBridgeControlService";
    pub const custom_tool_callback = "sdk.v1.SdkCustomToolCallbackService";
    pub const store_callback = "sdk.v1.SdkStoreCallbackService";
};

pub fn rpcPath(service: []const u8, method: []const u8) [2][]const u8 {
    return .{ service, method };
}

comptime {
    _ = Bridge;
    _ = spawn;
    _ = findBridgeBinary;
    _ = Hub;
    _ = Waiter;
    _ = Service;
}

test "official bridge is Connect HTTP, not a C ABI" {
    try @import("std").testing.expect(!has_c_abi);
    try @import("std").testing.expectEqualStrings("sdk.v1", protocol_version);
    try @import("std").testing.expectEqualStrings("sdk.v1.SdkAgentService", Service.agent);
}
