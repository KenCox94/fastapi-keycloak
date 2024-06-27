const std = @import("std");
const http = std.http;
const ArrayList = std.ArrayList;

var allocator = std.heap.page_allocator;

const AccessToken = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: u64 = 0,
    refresh_expires_in: u64 = 0,
    notbeforepolicy: u8 = 0,
};

const Group = struct {
    id: []const u8,
};

pub fn build(b: *std.Build) !void {
    dockerUp(b);
    try pytest(b);
    dockerTearDown(b);
}

fn auth() !std.json.Parsed(AccessToken) {
    var buffer: [1048]u8 = undefined;

    const resp = try sendApiRequest(&allocator, "http://localhost:8085/realms/Test/protocol/openid-connect/token", .POST, .{
        .server_header_buffer = &buffer,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
    }, "grant_type=client_credentials&client_secret=BIcczGsZ6I8W5zf0rZg5qSexlloQLPKB&client_id=admin-cli");
    defer allocator.free(resp);

    const token = try std.json.parseFromSlice(AccessToken, allocator, resp, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });

    return token;
}

fn cleanUp(token: *const std.json.Parsed(AccessToken)) !void {
    var buffer: [1048]u8 = undefined;

    const auth_header = try std.fmt.allocPrint(allocator, "{s} {s}", .{ token.value.token_type, token.value.access_token });
    defer allocator.free(auth_header);
    const resp = try sendApiRequest(&allocator, "http://localhost:8085/admin/realms/Test/groups", .GET, .{
        .server_header_buffer = &buffer,
        .headers = .{
            .content_type = .default,
            .authorization = .{ .override = auth_header },
        },
    }, null);

    var it = std.mem.trimLeft(u8, resp, "[");
    it = std.mem.trim(u8, it, "]");
    var split = std.mem.splitSequence(u8, it, "},");
    var list = ArrayList(std.json.Parsed(Group)).init(allocator);
    defer list.deinit();

    while (split.next()) |str| {
        const idx = std.mem.lastIndexOf(u8, str, "}}");
        var value = str;
        if (idx == null) {
            value = try std.mem.join(allocator, "", &[_][]const u8{ str, "}" });
            defer allocator.free(value);

            const group = try std.json.parseFromSlice(Group, allocator, value, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            });

            try list.append(group);
        } else {
            const group = try std.json.parseFromSlice(Group, allocator, value, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            });

            try list.append(group);
        }
    }

    for (list.items) |i| {
        const url = try std.fmt.allocPrint(allocator, "http://localhost:8085/admin/realms/Test/groups/{s}", .{i.value.id});
        _ = try sendApiRequest(&allocator, url, .DELETE, .{
            .server_header_buffer = &buffer,
            .headers = .{
                .content_type = .default,
                .authorization = .{ .override = auth_header },
            },
        }, null);
    }
}

fn sendApiRequest(alloc: *std.mem.Allocator, url: []const u8, method: http.Method, options: http.Client.RequestOptions, request_body: ?[]const u8) ![]u8 {
    var client = std.http.Client{
        .allocator = alloc.*,
    };

    const uri = try std.Uri.parse(url);
    var req = try client.open(method, uri, options);

    switch (method) {
        .POST => {
            req.transfer_encoding = .chunked;
            try req.send();
            _ = try req.write(request_body.?);
            try req.finish();
        },
        else => {
            try req.send();
        },
    }

    try req.wait();

    const body = try req.reader().readAllAlloc(allocator, 4086);
    defer {
        req.deinit();
    }
    return body;
}

fn dockerUp(b: *std.Build) void {
    const docker_cmd = b.addSystemCommand(&[_][]const u8{ "docker", "compose", "-f", "tests/keycloak_postgres.yaml", "up", "-d" });
    const setup_step = b.step("setup", "run keycloak setup");

    setup_step.dependOn(&docker_cmd.step);
}

fn pytest(b: *std.Build) !void {
    const pytest_cmd = b.addSystemCommand(&[_][]const u8{ "poetry", "run", "pytest" });
    const pytest_step = b.step("pytest", "run python test");
    pytest_step.dependOn(&pytest_cmd.step);
    const token = try auth();
    defer token.deinit();
    try cleanUp(&token);
}

fn dockerTearDown(b: *std.Build) void {
    const docker_cmd = b.addSystemCommand(&[_][]const u8{ "docker", "compose", "-f", "tests/keycloak_postgres.yaml", "down" });
    const down_step = b.step("down", "tear down test suite");
    down_step.dependOn(&docker_cmd.step);
}
