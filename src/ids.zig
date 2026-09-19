const std = @import("std");
const Io = std.Io;

pub fn hexId(io: Io, prefix: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, hex[0..] });
}

pub fn requestId(io: Io, allocator: std.mem.Allocator) ![]u8 {
    return hexId(io, "req_", allocator);
}

pub fn messageId(io: Io, allocator: std.mem.Allocator) ![]u8 {
    return hexId(io, "msg_", allocator);
}

pub fn sessionId(io: Io, allocator: std.mem.Allocator) ![]u8 {
    return hexId(io, "ses_", allocator);
}

pub fn compactId(io: Io, allocator: std.mem.Allocator) ![]u8 {
    return hexId(io, "cmp_", allocator);
}

pub fn instanceId(io: Io, allocator: std.mem.Allocator, configured: ?[]const u8) ![]const u8 {
    if (configured) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return hexId(io, "inst_", allocator);
}

pub fn responseId(from_message_id: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.mem.startsWith(u8, from_message_id, "msg_")) {
        return std.fmt.allocPrint(allocator, "resp_{s}", .{from_message_id[4..]});
    }
    if (std.mem.startsWith(u8, from_message_id, "resp_")) {
        return allocator.dupe(u8, from_message_id);
    }
    return std.fmt.allocPrint(allocator, "resp_{s}", .{from_message_id});
}

pub fn chatCompletionId(from_message_id: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.mem.startsWith(u8, from_message_id, "msg_")) {
        return std.fmt.allocPrint(allocator, "chatcmpl_{s}", .{from_message_id[4..]});
    }
    return std.fmt.allocPrint(allocator, "chatcmpl_{s}", .{from_message_id});
}

pub fn reasoningItemId(message_id: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const rest = if (std.mem.startsWith(u8, message_id, "msg_"))
        message_id[4..]
    else if (std.mem.startsWith(u8, message_id, "resp_"))
        message_id[5..]
    else
        message_id;
    return std.fmt.allocPrint(allocator, "rs_{s}", .{rest});
}

pub fn functionCallItemId(call_id: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (std.mem.startsWith(u8, call_id, "fc_")) return allocator.dupe(u8, call_id);
    return std.fmt.allocPrint(allocator, "fc_{s}", .{call_id});
}

test "responseId maps msg_ prefix" {
    const id = try responseId("msg_abc", std.testing.allocator);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("resp_abc", id);
}
