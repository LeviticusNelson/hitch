const std = @import("std");

pub const Method = std.http.Method;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Incoming = struct {
    method: Method,
    target: []const u8,
    path: []const u8,
    version: []const u8,
    headers: []Header,
    body: []const u8,
    head: []const u8,
};

pub const ParseError = error{
    HeadersTooLarge,
    BodyTooLarge,
    InvalidRequestLine,
    UnknownMethod,
    Incomplete,
    Http2,
    OutOfMemory,
};

/// Split `METHOD SP TARGET SP HTTP/1.x` allowing extra spaces and LF-only lines.
pub fn parseRequestLine(line: []const u8) ParseError!struct { method: Method, target: []const u8, version: []const u8 } {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return error.Incomplete;
    if (std.mem.startsWith(u8, trimmed, "PRI * HTTP/2.0")) return error.Http2;

    var rest = trimmed;
    const sp1 = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidRequestLine;
    const method_s = rest[0..sp1];
    rest = std.mem.trimStart(u8, rest[sp1 + 1 ..], " \t");
    const sp2 = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return error.InvalidRequestLine;
    var target = std.mem.trim(u8, rest[0..sp2], " \t");
    const version = std.mem.trim(u8, rest[sp2 + 1 ..], " \t\r");
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.InvalidRequestLine;

    const method = parseMethod(method_s) orelse return error.UnknownMethod;
    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
        if (std.mem.indexOfScalar(u8, target[8..], '/')) |rel| {
            target = target[8 + rel ..];
        }
    }
    if (target.len == 0) target = "/";
    return .{ .method = method, .target = target, .version = version };
}

fn parseMethod(s: []const u8) ?Method {
    if (std.meta.stringToEnum(Method, s)) |m| return m;
    var buf: [16]u8 = undefined;
    if (s.len == 0 or s.len > buf.len) return null;
    const upper = std.ascii.upperString(&buf, s);
    return std.meta.stringToEnum(Method, upper);
}

pub fn extractPath(target: []const u8) []const u8 {
    var p = target;
    const q = std.mem.indexOfScalar(u8, p, '?') orelse p.len;
    p = p[0..q];
    while (std.mem.startsWith(u8, p, "/v1/v1/")) p = p[3..];
    if (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    return p;
}

pub fn findHeaderEnd(bytes: []const u8) ?usize {
    if (std.mem.indexOf(u8, bytes, "\r\n\r\n")) |i| return i + 4;
    if (std.mem.indexOf(u8, bytes, "\n\n")) |i| return i + 2;
    return null;
}

pub fn parseHead(arena: std.mem.Allocator, head: []const u8) ParseError!Incoming {
    const sep = findHeaderEnd(head) orelse return error.Incomplete;
    const header_block = head[0 .. sep - (if (std.mem.endsWith(u8, head[0..sep], "\r\n\r\n")) @as(usize, 4) else 2)];
    const nl: []const u8 = if (std.mem.indexOf(u8, header_block, "\r\n") != null) "\r\n" else "\n";
    var lines = std.mem.splitSequence(u8, header_block, nl);
    const req_line = lines.next() orelse return error.InvalidRequestLine;
    const rl = try parseRequestLine(req_line);

    var hdrs = std.ArrayList(Header).empty;
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const name = std.mem.trim(u8, raw[0..colon], " \t");
        const value = std.mem.trim(u8, raw[colon + 1 ..], " \t\r");
        if (name.len == 0) continue;
        try hdrs.append(arena, .{
            .name = try arena.dupe(u8, name),
            .value = try arena.dupe(u8, value),
        });
    }

    const path = try arena.dupe(u8, extractPath(rl.target));
    return .{
        .method = rl.method,
        .target = try arena.dupe(u8, rl.target),
        .path = path,
        .version = try arena.dupe(u8, rl.version),
        .headers = try hdrs.toOwnedSlice(arena),
        .body = &.{},
        .head = head[0..sep],
    };
}

pub fn header(req: Incoming, name: []const u8) ?[]const u8 {
    for (req.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

pub fn contentLength(req: Incoming) ?u64 {
    const v = header(req, "content-length") orelse return null;
    return std.fmt.parseInt(u64, v, 10) catch null;
}

test "parseRequestLine origin form" {
    const rl = try parseRequestLine("POST /v1/responses HTTP/1.1");
    try std.testing.expectEqual(Method.POST, rl.method);
    try std.testing.expectEqualStrings("/v1/responses", rl.target);
}

test "parseRequestLine extra spaces and absolute URL" {
    const rl = try parseRequestLine("POST  http://127.0.0.1:18091/v1/responses  HTTP/1.1");
    try std.testing.expectEqualStrings("/v1/responses", extractPath(rl.target));
}

test "parseRequestLine LF request with headers in same block" {
    const head = "POST /v1/responses HTTP/1.1\nHost: 127.0.0.1\nContent-Length: 2\n\n{}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try parseHead(arena.allocator(), head);
    try std.testing.expectEqual(Method.POST, req.method);
    try std.testing.expectEqualStrings("/v1/responses", req.path);
    try std.testing.expectEqualStrings("2", header(req, "content-length").?);
}

test "JSON leftover is not a valid request line" {
    const line = " duration). Something HTTP/1.1";
    try std.testing.expectError(error.UnknownMethod, parseRequestLine(line));
}

pub const Reply = struct {
    writer: *std.Io.Writer,
    started: bool = false,
    sse: bool = false,
    dead: bool = false,

    pub fn statusLine(code: u16) []const u8 {
        return switch (code) {
            200 => "200 OK",
            204 => "204 No Content",
            400 => "400 Bad Request",
            401 => "401 Unauthorized",
            404 => "404 Not Found",
            409 => "409 Conflict",
            413 => "413 Payload Too Large",
            422 => "422 Unprocessable Entity",
            429 => "429 Too Many Requests",
            499 => "499 Client Closed",
            500 => "500 Internal Server Error",
            502 => "502 Bad Gateway",
            504 => "504 Gateway Timeout",
            else => "500 Internal Server Error",
        };
    }

    pub fn writeHead(self: *Reply, code: u16, extra: []const std.http.Header) !void {
        if (self.started) return;
        self.started = true;
        try self.writer.print("HTTP/1.1 {s}\r\n", .{statusLine(code)});
        try self.writer.writeAll("connection: close\r\n");
        try self.writer.writeAll("cache-control: no-store\r\n");
        for (extra) |h| {
            try self.writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
    }

    pub fn json(self: *Reply, code: u16, body: []const u8, extra: []const std.http.Header) !void {
        var cl_buf: [32]u8 = undefined;
        const cl = try std.fmt.bufPrint(&cl_buf, "{d}", .{body.len});
        try self.writeHead(code, extra);
        try self.writer.print("content-length: {s}\r\n", .{cl});
        if (headerMissing(extra, "content-type")) {
            try self.writer.writeAll("content-type: application/json; charset=utf-8\r\n");
        }
        try self.writer.writeAll("\r\n");
        try self.writer.writeAll(body);
        try self.writer.flush();
    }

    pub fn empty(self: *Reply, code: u16, extra: []const std.http.Header) !void {
        try self.writeHead(code, extra);
        try self.writer.writeAll("content-length: 0\r\n\r\n");
        try self.writer.flush();
    }

    pub fn beginSse(self: *Reply, extra: []const std.http.Header) !void {
        try self.writeHead(200, extra);
        if (headerMissing(extra, "content-type")) {
            try self.writer.writeAll("content-type: text/event-stream; charset=utf-8\r\n");
        }
        try self.writer.writeAll("x-accel-buffering: no\r\n");
        try self.writer.writeAll("\r\n");
        try self.writer.flush();
        self.sse = true;
    }

    pub fn writeAll(self: *Reply, bytes: []const u8) !void {
        self.writer.writeAll(bytes) catch |err| {
            self.dead = true;
            return err;
        };
        self.writer.flush() catch |err| {
            self.dead = true;
            return err;
        };
    }

    pub fn end(self: *Reply) !void {
        try self.writer.flush();
    }
};

fn headerMissing(extra: []const std.http.Header, name: []const u8) bool {
    for (extra) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return false;
    }
    return true;
}

pub fn previewLine(bytes: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, bytes, "\r\n");
    const nl = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    return trimmed[0..@min(nl, 96)];
}

pub fn readIncoming(reader: *std.Io.Reader, writer: *std.Io.Writer, arena: std.mem.Allocator, max_head: usize, max_body: usize) !Incoming {
    var store = std.ArrayList(u8).empty;
    errdefer store.deinit(arena);

    var header_end: ?usize = null;
    while (header_end == null) {
        skipLeadingBlankLines(&store);
        if (findHeaderEnd(store.items)) |end| {
            header_end = end;
            break;
        }
        const buf = reader.buffered();
        if (buf.len == 0) {
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => {
                    if (store.items.len == 0) return error.Incomplete;
                    std.log.warn("http incomplete headers first={s}", .{previewLine(store.items)});
                    return error.Incomplete;
                },
                else => return err,
            };
            continue;
        }
        const room = if (store.items.len >= max_head) 0 else max_head - store.items.len;
        if (room == 0) return error.HeadersTooLarge;
        const take = @min(room, buf.len);
        try store.appendSlice(arena, buf[0..take]);
        reader.toss(take);
        if (findHeaderEnd(store.items) == null and store.items.len >= max_head) return error.HeadersTooLarge;
    }

    const end = header_end.?;
    const leftover = store.items[end..];
    var req = parseHead(arena, store.items[0..end]) catch |err| {
        std.log.warn("http rejected request line ({t}): {s}", .{ err, previewLine(store.items) });
        return err;
    };

    if (header(req, "expect")) |ex| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, ex, " "), "100-continue")) {
            try writer.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
            try writer.flush();
        }
    }

    if (contentLength(req)) |n_u64| {
        if (n_u64 > max_body) return error.BodyTooLarge;
        const n: usize = @intCast(n_u64);
        if (n > 0) {
            const body = try arena.alloc(u8, n);
            const prefix_n = @min(leftover.len, n);
            if (prefix_n > 0) @memcpy(body[0..prefix_n], leftover[0..prefix_n]);
            if (prefix_n < n) try reader.readSliceAll(body[prefix_n..]);
            req.body = body;
        }
    } else if (req.method.requestHasBody()) {
        const te = header(req, "transfer-encoding") orelse "";
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, te, " "), "chunked")) {
            req.body = try readChunkedPrefixed(reader, leftover, arena, max_body);
        }
    }
    return req;
}

fn skipLeadingBlankLines(store: *std.ArrayList(u8)) void {
    var i: usize = 0;
    while (i < store.items.len) {
        if (store.items[i] == '\n') {
            i += 1;
            continue;
        }
        if (store.items[i] == '\r' and i + 1 < store.items.len and store.items[i + 1] == '\n') {
            i += 2;
            continue;
        }
        break;
    }
    if (i == 0) return;
    const remain = store.items.len - i;
    std.mem.copyForwards(u8, store.items[0..remain], store.items[i..]);
    store.items.len = remain;
}

test "readIncoming consumes Content-Length body and ignores leftover bytes" {
    const raw =
        "POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 13\r\n\r\n{\"model\":\"x\"} duration). S leftover";
    var reader = std.Io.Reader.fixed(raw);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try readIncoming(&reader, &aw.writer, arena.allocator(), 4096, 1024);
    try std.testing.expectEqual(Method.POST, req.method);
    try std.testing.expectEqualStrings("/v1/responses", req.path);
    try std.testing.expectEqualStrings("{\"model\":\"x\"}", req.body);
}

test "readIncoming header terminator split from body" {
    const raw = "POST /v1/responses HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}";
    var reader = std.Io.Reader.fixed(raw);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try readIncoming(&reader, &aw.writer, arena.allocator(), 4096, 1024);
    try std.testing.expectEqualStrings("{}", req.body);
}

test "readIncoming answers 100-continue" {
    const raw = "POST /v1/responses HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n{}";
    var reader = std.Io.Reader.fixed(raw);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try readIncoming(&reader, &aw.writer, arena.allocator(), 4096, 1024);
    try std.testing.expectEqualStrings("{}", req.body);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "100 Continue") != null);
}

fn takeLinePrefixed(reader: *std.Io.Reader, prefix: *[]const u8, arena: std.mem.Allocator) ![]const u8 {
    if (std.mem.indexOfScalar(u8, prefix.*, '\n')) |i| {
        const line = prefix.*[0 .. i + 1];
        prefix.* = prefix.*[i + 1 ..];
        return line;
    }
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(arena, prefix.*);
    prefix.* = &.{};
    const rest = try reader.takeDelimiterInclusive('\n');
    try out.appendSlice(arena, rest);
    return out.items;
}

fn takeBytesPrefixed(reader: *std.Io.Reader, prefix: *[]const u8, arena: std.mem.Allocator, n: usize) ![]u8 {
    const out = try arena.alloc(u8, n);
    const from_prefix = @min(n, prefix.len);
    if (from_prefix > 0) @memcpy(out[0..from_prefix], prefix.*[0..from_prefix]);
    prefix.* = prefix.*[from_prefix..];
    if (from_prefix < n) try reader.readSliceAll(out[from_prefix..]);
    return out;
}

fn readChunkedPrefixed(reader: *std.Io.Reader, leftover: []const u8, arena: std.mem.Allocator, max_body: usize) ![]u8 {
    var prefix = leftover;
    var body = std.ArrayList(u8).empty;
    while (true) {
        const line = try takeLinePrefixed(reader, &prefix, arena);
        const hex = std.mem.trim(u8, line, " \t\r\n");
        const semi = std.mem.indexOfScalar(u8, hex, ';') orelse hex.len;
        const n = std.fmt.parseInt(usize, hex[0..semi], 16) catch return error.InvalidRequestLine;
        if (n == 0) {
            _ = takeLinePrefixed(reader, &prefix, arena) catch {};
            break;
        }
        if (body.items.len + n > max_body) return error.BodyTooLarge;
        const chunk = try takeBytesPrefixed(reader, &prefix, arena, n);
        try body.appendSlice(arena, chunk);
        _ = try takeLinePrefixed(reader, &prefix, arena);
    }
    return body.toOwnedSlice(arena);
}

fn readChunked(reader: *std.Io.Reader, arena: std.mem.Allocator, max_body: usize) ![]u8 {
    return readChunkedPrefixed(reader, &.{}, arena, max_body);
}
