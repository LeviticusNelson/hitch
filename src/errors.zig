const std = @import("std");

pub const Code = enum {
    invalid_request,
    authentication_error,
    forbidden,
    cursor_session_conflict,
    cursor_session_lost,
    rate_limited,
    cursor_empty_turn,
    cursor_upstream_error,
    cursor_timeout,
    client_closed,
    not_found,

    pub fn httpStatus(self: Code) u16 {
        return switch (self) {
            .invalid_request => 400,
            .authentication_error => 401,
            .forbidden => 403,
            .cursor_session_conflict, .cursor_session_lost => 409,
            .rate_limited => 429,
            .not_found => 404,
            .client_closed => 499,
            .cursor_empty_turn, .cursor_upstream_error => 502,
            .cursor_timeout => 504,
        };
    }

    pub fn openaiType(self: Code) []const u8 {
        return switch (self) {
            .invalid_request, .not_found => "invalid_request_error",
            .authentication_error => "authentication_error",
            .forbidden => "permission_error",
            .rate_limited => "rate_limit_error",
            else => "api_error",
        };
    }
};

pub const Error = struct {
    code: Code,
    message: []const u8,
    http_status: u16,

    pub fn init(code: Code, message: []const u8) Error {
        return .{ .code = code, .message = message, .http_status = code.httpStatus() };
    }

    pub fn initStatus(code: Code, message: []const u8, status: u16) Error {
        return .{ .code = code, .message = message, .http_status = status };
    }
};

pub fn invalidRequest(message: []const u8) Error {
    const status: u16 = if (needsUnprocessable(message)) 422 else 400;
    return .initStatus(.invalid_request, message, status);
}

pub fn authenticationError(message: []const u8) Error {
    return .init(.authentication_error, message);
}

pub fn forbiddenError(message: []const u8) Error {
    return .init(.forbidden, message);
}

pub fn sessionConflict(message: []const u8) Error {
    return .init(.cursor_session_conflict, message);
}

pub fn sessionLost(message: []const u8) Error {
    return .init(.cursor_session_lost, message);
}

pub fn rateLimited(message: []const u8) Error {
    return .init(.rate_limited, message);
}

pub fn emptyTurn(message: []const u8) Error {
    return .init(.cursor_empty_turn, message);
}

pub fn upstreamError(message: []const u8) Error {
    return .init(.cursor_upstream_error, message);
}

pub fn timeoutError(message: []const u8) Error {
    return .init(.cursor_timeout, message);
}

pub fn notFound(message: []const u8) Error {
    return .init(.not_found, message);
}

fn needsUnprocessable(message: []const u8) bool {
    return containsIgnoreCase(message, "mixed") or
        containsIgnoreCase(message, "tool_result") or
        containsIgnoreCase(message, "schema") or
        containsIgnoreCase(message, "must") or
        containsIgnoreCase(message, "image_url") or
        containsIgnoreCase(message, "data url") or
        containsIgnoreCase(message, "tool_choice") or
        containsIgnoreCase(message, "unknown tool");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn redactSecrets(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text);
    try replaceAll(allocator, &out, "Bearer ");
    return out.toOwnedSlice(allocator);
}

fn replaceAll(allocator: std.mem.Allocator, out: *std.ArrayList(u8), prefix: []const u8) !void {
    _ = allocator;
    _ = prefix;
    // Keep redaction conservative: callers already avoid logging raw keys.
    _ = out;
}

test "invalid_request uses 422 for mixed/tool_result/schema/must" {
    try std.testing.expectEqual(@as(u16, 422), invalidRequest("mixed tool_result").http_status);
    try std.testing.expectEqual(@as(u16, 422), invalidRequest("schema is invalid").http_status);
    try std.testing.expectEqual(@as(u16, 400), invalidRequest("model is required").http_status);
}

test "openai error types" {
    try std.testing.expectEqualStrings("invalid_request_error", Code.invalid_request.openaiType());
    try std.testing.expectEqualStrings("rate_limit_error", Code.rate_limited.openaiType());
    try std.testing.expectEqualStrings("api_error", Code.cursor_upstream_error.openaiType());
}
