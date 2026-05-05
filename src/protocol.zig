const std = @import("std");
const bio = @import("bioformats");

const max_image_bytes = 512 * 1024 * 1024;

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    handles: std.ArrayList(Handle) = .empty,
    next_handle_id: u64 = 1,

    const Handle = struct {
        id: u64,
        path: []u8,
        bytes: []u8,
        metadata: bio.Metadata,

        fn deinit(self: Handle, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            allocator.free(self.bytes);
        }
    };

    const RequestOutcome = struct {
        should_shutdown: bool = false,
        wrote_response: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Server {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Server) void {
        for (self.handles.items) |handle| handle.deinit(self.allocator);
        self.handles.deinit(self.allocator);
    }

    pub fn handleLine(self: *Server, line: []const u8, writer: *std.Io.Writer) !bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            try writeError(writer, .null, -32700, "Parse error");
            try writer.writeByte('\n');
            return false;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root == .array) {
            if (root.array.items.len == 0) {
                try writeError(writer, .null, -32600, "Invalid Request");
                try writer.writeByte('\n');
                return false;
            }

            var should_shutdown = false;
            var wrote_any = false;
            for (root.array.items) |request| {
                if (request != .object) {
                    if (wrote_any) {
                        try writer.writeByte(',');
                    } else {
                        try writer.writeByte('[');
                        wrote_any = true;
                    }
                    try writeError(writer, .null, -32600, "Invalid Request");
                    continue;
                }
                var response: std.Io.Writer.Allocating = .init(self.allocator);
                defer response.deinit();
                const outcome = try self.handleRequest(request, &response.writer);
                should_shutdown = outcome.should_shutdown or should_shutdown;
                if (outcome.wrote_response) {
                    if (wrote_any) {
                        try writer.writeByte(',');
                    } else {
                        try writer.writeByte('[');
                        wrote_any = true;
                    }
                    try writer.writeAll(response.written());
                }
            }
            if (wrote_any) try writer.writeAll("]\n");
            return should_shutdown;
        }

        if (root != .object) {
            try writeError(writer, .null, -32600, "Invalid Request");
            try writer.writeByte('\n');
            return false;
        }

        const outcome = try self.handleRequest(root, writer);
        if (outcome.wrote_response) try writer.writeByte('\n');
        return outcome.should_shutdown;
    }

    fn handleRequest(self: *Server, request: std.json.Value, writer: *std.Io.Writer) !RequestOutcome {
        const object = request.object;
        const has_id = object.get("id") != null;
        const id = object.get("id") orelse std.json.Value.null;
        if (has_id and !isValidRequestId(id)) {
            try writeError(writer, .null, -32600, "Invalid id");
            return .{ .wrote_response = true };
        }
        const jsonrpc_value = object.get("jsonrpc") orelse {
            try writeError(writer, id, -32600, "Invalid JSON-RPC version");
            return .{ .wrote_response = true };
        };
        if (jsonrpc_value != .string or !std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
            try writeError(writer, id, -32600, "Invalid JSON-RPC version");
            return .{ .wrote_response = true };
        }
        const method_value = object.get("method") orelse {
            try writeError(writer, id, -32600, "Missing method");
            return .{ .wrote_response = true };
        };
        if (method_value != .string) {
            try writeError(writer, id, -32600, "Method must be a string");
            return .{ .wrote_response = true };
        }

        const params = object.get("params");
        const method = method_value.string;
        if (!has_id) return self.handleNotification(method, params);
        if (requiresObjectParams(method)) {
            if (params) |params_value| {
                if (params_value != .object) {
                    try writeError(writer, id, -32602, "Invalid params");
                    return .{ .wrote_response = true };
                }
            }
        }
        if (std.mem.eql(u8, method, "initialize")) {
            try writeInitialize(writer, id);
        } else if (std.mem.eql(u8, method, "formats")) {
            try writeFormats(writer, id);
        } else if (std.mem.eql(u8, method, "probe")) {
            if (hasMultipleInputSources(params)) {
                try writeError(writer, id, -32602, "Invalid params");
                return .{ .wrote_response = true };
            }
            switch (try getDataParam(self.allocator, params)) {
                .value => |bytes| {
                    defer self.allocator.free(bytes);
                    try writeProbe(writer, id, "<inline>", bytes);
                    return .{ .wrote_response = true };
                },
                .invalid => {
                    try writeError(writer, id, -32602, "Invalid params.data");
                    return .{ .wrote_response = true };
                },
                .missing => {},
            }
            const path = switch (getPathParam(params)) {
                .value => |path| path,
                .invalid => {
                    try writeError(writer, id, -32602, "Invalid params.path");
                    return .{ .wrote_response = true };
                },
                .missing => {
                    try writeError(writer, id, -32602, "Missing params.path or params.data");
                    return .{ .wrote_response = true };
                },
            };
            const bytes = readFile(self.allocator, self.io, path) catch |err| {
                try writeReaderError(writer, id, err);
                return .{ .wrote_response = true };
            };
            defer self.allocator.free(bytes);
            if (try self.probePathPriorityFormat(path)) |format| {
                try writeProbeFormat(writer, id, path, format);
                return .{ .wrote_response = true };
            }
            if (bio.detect(bytes) == null) {
                if (try self.probeCompanionFormat(path)) |format| {
                    try writeProbeFormat(writer, id, path, format);
                    return .{ .wrote_response = true };
                }
            }
            try writeProbe(writer, id, path, bytes);
        } else if (std.mem.eql(u8, method, "open")) {
            try self.openPath(writer, id, params);
        } else if (std.mem.eql(u8, method, "close")) {
            try self.closeHandle(writer, id, params);
        } else if (std.mem.eql(u8, method, "metadata")) {
            if (hasMultipleInputSources(params)) {
                try writeError(writer, id, -32602, "Invalid params");
                return .{ .wrote_response = true };
            }
            switch (getHandleParam(params)) {
                .value => |handle_id| {
                    const handle = self.findHandle(handle_id) orelse {
                        try writeError(writer, id, -32001, "Invalid handle");
                        return .{ .wrote_response = true };
                    };
                    try beginResult(writer, id);
                    try writeMetadataObject(writer, handle.metadata);
                    try endMessage(writer);
                },
                .invalid => {
                    try writeError(writer, id, -32602, "Invalid params.handle");
                    return .{ .wrote_response = true };
                },
                .missing => {
                    switch (try getDataParam(self.allocator, params)) {
                        .value => |bytes| {
                            defer self.allocator.free(bytes);
                            const metadata = bio.readMetadata(bytes) catch |err| {
                                try writeReaderError(writer, id, err);
                                return .{ .wrote_response = true };
                            };
                            try beginResult(writer, id);
                            try writeMetadataObject(writer, metadata);
                            try endMessage(writer);
                            return .{ .wrote_response = true };
                        },
                        .invalid => {
                            try writeError(writer, id, -32602, "Invalid params.data");
                            return .{ .wrote_response = true };
                        },
                        .missing => {},
                    }
                    const path = switch (getPathParam(params)) {
                        .value => |path| path,
                        .invalid => {
                            try writeError(writer, id, -32602, "Invalid params.path");
                            return .{ .wrote_response = true };
                        },
                        .missing => {
                            try writeError(writer, id, -32602, "Missing params.path, params.handle, or params.data");
                            return .{ .wrote_response = true };
                        },
                    };
                    const bytes = readFile(self.allocator, self.io, path) catch |err| {
                        try writeReaderError(writer, id, err);
                        return .{ .wrote_response = true };
                    };
                    defer self.allocator.free(bytes);
                    const metadata = self.metadataFromPathBytes(path, bytes) catch |err| {
                        try writeReaderError(writer, id, err);
                        return .{ .wrote_response = true };
                    };
                    try beginResult(writer, id);
                    try writeMetadataObject(writer, metadata);
                    try endMessage(writer);
                },
            }
        } else if (std.mem.eql(u8, method, "readPlane")) {
            if (hasMultipleInputSources(params)) {
                try writeError(writer, id, -32602, "Invalid params");
                return .{ .wrote_response = true };
            }
            switch (getHandleParam(params)) {
                .value => |handle_id| {
                    const handle = self.findHandle(handle_id) orelse {
                        try writeError(writer, id, -32001, "Invalid handle");
                        return .{ .wrote_response = true };
                    };
                    const plane_index = getPlaneIndex(params, handle.metadata) catch {
                        try writeError(writer, id, -32602, "Invalid plane index");
                        return .{ .wrote_response = true };
                    };
                    const region = getRegion(params, handle.metadata) catch {
                        try writeError(writer, id, -32602, "Invalid plane region");
                        return .{ .wrote_response = true };
                    };
                    const plane = if (isPathBackedCompanion(handle))
                        self.readCompanionPlane(handle.metadata.format, handle.path, plane_index, region) catch |err| {
                            try writeReaderError(writer, id, err);
                            return .{ .wrote_response = true };
                        }
                    else
                        bio.readPlaneRegionIndex(self.allocator, handle.bytes, plane_index, region) catch |err| {
                            try writeReaderError(writer, id, err);
                            return .{ .wrote_response = true };
                        };
                    defer self.allocator.free(plane.data);
                    try writePlane(writer, self.allocator, id, plane, region);
                },
                .invalid => {
                    try writeError(writer, id, -32602, "Invalid params.handle");
                    return .{ .wrote_response = true };
                },
                .missing => {
                    switch (try getDataParam(self.allocator, params)) {
                        .value => |bytes| {
                            defer self.allocator.free(bytes);
                            const metadata = bio.readMetadata(bytes) catch |err| {
                                try writeReaderError(writer, id, err);
                                return .{ .wrote_response = true };
                            };
                            const plane_index = getPlaneIndex(params, metadata) catch {
                                try writeError(writer, id, -32602, "Invalid plane index");
                                return .{ .wrote_response = true };
                            };
                            const region = getRegion(params, metadata) catch {
                                try writeError(writer, id, -32602, "Invalid plane region");
                                return .{ .wrote_response = true };
                            };
                            const plane = bio.readPlaneRegionIndex(self.allocator, bytes, plane_index, region) catch |err| {
                                try writeReaderError(writer, id, err);
                                return .{ .wrote_response = true };
                            };
                            defer self.allocator.free(plane.data);
                            try writePlane(writer, self.allocator, id, plane, region);
                            return .{ .wrote_response = true };
                        },
                        .invalid => {
                            try writeError(writer, id, -32602, "Invalid params.data");
                            return .{ .wrote_response = true };
                        },
                        .missing => {},
                    }
                    const path = switch (getPathParam(params)) {
                        .value => |path| path,
                        .invalid => {
                            try writeError(writer, id, -32602, "Invalid params.path");
                            return .{ .wrote_response = true };
                        },
                        .missing => {
                            try writeError(writer, id, -32602, "Missing params.path, params.handle, or params.data");
                            return .{ .wrote_response = true };
                        },
                    };
                    const bytes = readFile(self.allocator, self.io, path) catch |err| {
                        try writeReaderError(writer, id, err);
                        return .{ .wrote_response = true };
                    };
                    defer self.allocator.free(bytes);
                    const metadata = self.metadataFromPathBytes(path, bytes) catch |err| {
                        try writeReaderError(writer, id, err);
                        return .{ .wrote_response = true };
                    };
                    const plane_index = getPlaneIndex(params, metadata) catch {
                        try writeError(writer, id, -32602, "Invalid plane index");
                        return .{ .wrote_response = true };
                    };
                    const region = getRegion(params, metadata) catch {
                        try writeError(writer, id, -32602, "Invalid plane region");
                        return .{ .wrote_response = true };
                    };
                    const plane = if (isCompanionFormat(metadata.format))
                        self.readCompanionPlane(metadata.format, path, plane_index, region) catch |err| {
                            try writeReaderError(writer, id, err);
                            return .{ .wrote_response = true };
                        }
                    else
                        bio.readPlaneRegionIndex(self.allocator, bytes, plane_index, region) catch |err| {
                            try writeReaderError(writer, id, err);
                            return .{ .wrote_response = true };
                        };
                    defer self.allocator.free(plane.data);
                    try writePlane(writer, self.allocator, id, plane, region);
                },
            }
        } else if (std.mem.eql(u8, method, "shutdown")) {
            try beginResult(writer, id);
            try writer.writeAll("null");
            try endMessage(writer);
            return .{ .should_shutdown = true, .wrote_response = true };
        } else {
            try writeError(writer, id, -32601, "Method not found");
        }

        return .{ .wrote_response = true };
    }

    fn handleNotification(self: *Server, method: []const u8, params: ?std.json.Value) RequestOutcome {
        if (std.mem.eql(u8, method, "shutdown")) return .{ .should_shutdown = true };
        if (std.mem.eql(u8, method, "close")) {
            const handle_id = getHandleId(params) orelse return .{};
            for (self.handles.items, 0..) |handle, i| {
                if (handle.id == handle_id) {
                    const removed = self.handles.orderedRemove(i);
                    removed.deinit(self.allocator);
                    break;
                }
            }
        }
        return .{};
    }

    fn openPath(self: *Server, writer: *std.Io.Writer, id: std.json.Value, params: ?std.json.Value) !void {
        if (hasMultipleInputSources(params)) {
            try writeError(writer, id, -32602, "Invalid params");
            return;
        }
        switch (try getDataParam(self.allocator, params)) {
            .value => |bytes| {
                errdefer self.allocator.free(bytes);
                const metadata = bio.readMetadata(bytes) catch |err| {
                    try writeReaderError(writer, id, err);
                    self.allocator.free(bytes);
                    return;
                };
                const path_copy = try self.allocator.dupe(u8, "<inline>");
                errdefer self.allocator.free(path_copy);

                const handle_id = self.next_handle_id;
                self.next_handle_id += 1;
                try self.handles.append(self.allocator, .{
                    .id = handle_id,
                    .path = path_copy,
                    .bytes = bytes,
                    .metadata = metadata,
                });

                try beginResult(writer, id);
                try writer.print("{{\"handle\":{},\"path\":\"<inline>\",\"metadata\":", .{handle_id});
                try writeMetadataObject(writer, metadata);
                try writer.writeByte('}');
                try endMessage(writer);
                return;
            },
            .invalid => {
                try writeError(writer, id, -32602, "Invalid params.data");
                return;
            },
            .missing => {},
        }
        const path = switch (getPathParam(params)) {
            .value => |path| path,
            .invalid => {
                try writeError(writer, id, -32602, "Invalid params.path");
                return;
            },
            .missing => {
                try writeError(writer, id, -32602, "Missing params.path or params.data");
                return;
            },
        };
        const bytes = readFile(self.allocator, self.io, path) catch |err| {
            try writeReaderError(writer, id, err);
            return;
        };
        errdefer self.allocator.free(bytes);
        const metadata = self.metadataFromPathBytes(path, bytes) catch |err| {
            try writeReaderError(writer, id, err);
            return;
        };
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const handle_id = self.next_handle_id;
        self.next_handle_id += 1;
        try self.handles.append(self.allocator, .{
            .id = handle_id,
            .path = path_copy,
            .bytes = bytes,
            .metadata = metadata,
        });

        try beginResult(writer, id);
        try writer.print("{{\"handle\":{},\"path\":", .{handle_id});
        try writeJson(writer, path);
        try writer.writeAll(",\"metadata\":");
        try writeMetadataObject(writer, metadata);
        try writer.writeByte('}');
        try endMessage(writer);
    }

    fn closeHandle(self: *Server, writer: *std.Io.Writer, id: std.json.Value, params: ?std.json.Value) !void {
        if (hasMultipleInputSources(params)) {
            try writeError(writer, id, -32602, "Invalid params");
            return;
        }
        const handle_id = switch (getHandleParam(params)) {
            .value => |handle| handle,
            .invalid => {
                try writeError(writer, id, -32602, "Invalid params.handle");
                return;
            },
            .missing => {
                try writeError(writer, id, -32602, "Missing params.handle");
                return;
            },
        };
        for (self.handles.items, 0..) |handle, i| {
            if (handle.id == handle_id) {
                const removed = self.handles.orderedRemove(i);
                removed.deinit(self.allocator);
                try beginResult(writer, id);
                try writer.writeAll("true");
                try endMessage(writer);
                return;
            }
        }
        try writeError(writer, id, -32001, "Invalid handle");
    }

    fn findHandle(self: *Server, handle_id: u64) ?*const Handle {
        for (self.handles.items) |*handle| {
            if (handle.id == handle_id) return handle;
        }
        return null;
    }

    fn metadataFromPathBytes(self: *Server, path: []const u8, bytes: []const u8) !bio.Metadata {
        if (bio.afi.isPath(path)) {
            if (bio.afi.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.apl.isPath(path)) {
            if (bio.apl.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.l2d.isPath(path)) {
            if (bio.l2d.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.bdpathway.isPath(path)) {
            if (bio.bdpathway.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.bdv.isPath(path)) {
            if (bio.bdv.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.cellworx.isPath(path)) {
            if (bio.cellworx.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.cellsens.isPath(path)) {
            if (bio.cellsens.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.olympustile.isPath(path)) {
            if (bio.olympustile.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.cellvoyager.isPath(path)) {
            if (bio.cellvoyager.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.incell.isPath(path)) {
            if (bio.incell.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.columbus.isPath(path)) {
            if (bio.columbus.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.cv7000.isPath(path)) {
            if (bio.cv7000.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.jdce.isPath(path)) {
            if (bio.jdce.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.metaxpress.isPath(path)) {
            if (bio.metaxpress.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.micromanager.isPath(path)) {
            if (bio.micromanager.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.fake.isPath(path)) {
            if (bio.fake.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.visitech.isPath(path)) {
            if (bio.visitech.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.bruker.isPath(path)) {
            if (bio.bruker.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.filepattern.isPath(path)) {
            if (bio.filepattern.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.tecan.isPath(path)) {
            if (bio.tecan.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.tillvision.isPath(path)) {
            if (bio.tillvision.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.flex.isPath(path)) {
            if (bio.flex.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.fv1000.isPath(path)) {
            if (bio.fv1000.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.jpx.isPath(path)) {
            if (bio.jpx.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.hamamatsuvms.isPath(path)) {
            if (bio.hamamatsuvms.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.zeisstiff.isPath(path)) {
            if (bio.zeisstiff.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.pcoraw.isPath(path)) {
            if (bio.pcoraw.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.jpk.isPath(path)) {
            if (bio.jpk.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.imaristiff.isPath(path)) {
            if (bio.imaristiff.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.rcpnl.isPath(path)) {
            if (bio.rcpnl.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.ndpis.isPath(path)) {
            if (bio.ndpis.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.perkinelmer.isPath(path)) {
            if (bio.perkinelmer.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.spc.isPath(path)) {
            if (bio.spc.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        if (bio.xlef.isPath(path)) {
            if (bio.xlef.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
        }
        return bio.readMetadata(bytes) catch |err| {
            if (bio.analyze.isPath(path)) {
                if (bio.analyze.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
            }
            if (bio.pds.isPath(path)) {
                if (bio.pds.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
            }
            if (bio.ndpis.isPath(path)) {
                if (bio.ndpis.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
            }
            if (bio.inveon.isPath(path)) {
                if (bio.inveon.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
            }
            if (bio.fuji.isPath(path)) {
                if (bio.fuji.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
            }
            if (bio.hitachi.isPath(path)) {
                if (bio.hitachi.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
            }
            if (bio.imagic.isPath(path)) {
                if (bio.imagic.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
            }
            if (bio.ics.isPath(path)) {
                if (bio.ics.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
            }
            if (bio.unisoku.isPath(path)) {
                if (bio.unisoku.readMetadataPath(self.allocator, self.io, path)) |metadata| return metadata else |_| {}
            }
            return err;
        };
    }

    fn probePathPriorityFormat(self: *Server, path: []const u8) !?[]const u8 {
        if (bio.afi.isPath(path)) {
            if (bio.afi.readMetadataPath(self.allocator, self.io, path)) |_| return "afi" else |_| {}
        }
        if (bio.apl.isPath(path)) {
            if (bio.apl.readMetadataPath(self.allocator, self.io, path)) |_| return "apl" else |_| {}
        }
        if (bio.l2d.isPath(path)) {
            if (bio.l2d.readMetadataPath(self.allocator, self.io, path)) |_| return "l2d" else |_| {}
        }
        if (bio.bdpathway.isPath(path)) {
            if (bio.bdpathway.readMetadataPath(self.allocator, self.io, path)) |_| return "bdpathway" else |_| {}
        }
        if (bio.bdv.isPath(path)) {
            if (bio.bdv.readMetadataPath(self.allocator, self.io, path)) |_| return "bdv" else |_| {}
        }
        if (bio.cellworx.isPath(path)) {
            if (bio.cellworx.readMetadataPath(self.allocator, self.io, path)) |_| return "cellworx" else |_| {}
        }
        if (bio.cellsens.isPath(path)) {
            if (bio.cellsens.readMetadataPath(self.allocator, self.io, path)) |_| return "cellsens" else |_| {}
        }
        if (bio.olympustile.isPath(path)) {
            if (bio.olympustile.readMetadataPath(self.allocator, self.io, path)) |_| return "olympustile" else |_| {}
        }
        if (bio.cellvoyager.isPath(path)) {
            if (bio.cellvoyager.readMetadataPath(self.allocator, self.io, path)) |_| return "cellvoyager" else |_| {}
        }
        if (bio.incell.isPath(path)) {
            if (bio.incell.readMetadataPath(self.allocator, self.io, path)) |_| return "incell" else |_| {}
        }
        if (bio.columbus.isPath(path)) {
            if (bio.columbus.readMetadataPath(self.allocator, self.io, path)) |_| return "columbus" else |_| {}
        }
        if (bio.cv7000.isPath(path)) {
            if (bio.cv7000.readMetadataPath(self.allocator, self.io, path)) |_| return "cv7000" else |_| {}
        }
        if (bio.jdce.isPath(path)) {
            if (bio.jdce.readMetadataPath(self.allocator, self.io, path)) |_| return "jdce" else |_| {}
        }
        if (bio.metaxpress.isPath(path)) {
            if (bio.metaxpress.readMetadataPath(self.allocator, self.io, path)) |_| return "metaxpress" else |_| {}
        }
        if (bio.micromanager.isPath(path)) {
            if (bio.micromanager.readMetadataPath(self.allocator, self.io, path)) |_| return "micromanager" else |_| {}
        }
        if (bio.fake.isPath(path)) {
            if (bio.fake.readMetadataPath(self.allocator, self.io, path)) |_| return "fake" else |_| {}
        }
        if (bio.visitech.isPath(path)) {
            if (bio.visitech.readMetadataPath(self.allocator, self.io, path)) |_| return "visitech" else |_| {}
        }
        if (bio.bruker.isPath(path)) {
            if (bio.bruker.readMetadataPath(self.allocator, self.io, path)) |_| return "bruker" else |_| {}
        }
        if (bio.filepattern.isPath(path)) {
            if (bio.filepattern.readMetadataPath(self.allocator, self.io, path)) |_| return "filepattern" else |_| {}
        }
        if (bio.tecan.isPath(path)) {
            if (bio.tecan.readMetadataPath(self.allocator, self.io, path)) |_| return "tecan" else |_| {}
        }
        if (bio.tillvision.isPath(path)) {
            if (bio.tillvision.readMetadataPath(self.allocator, self.io, path)) |_| return "tillvision" else |_| {}
        }
        if (bio.flex.isPath(path)) {
            if (bio.flex.readMetadataPath(self.allocator, self.io, path)) |_| return "flex" else |_| {}
        }
        if (bio.fv1000.isPath(path)) {
            if (bio.fv1000.readMetadataPath(self.allocator, self.io, path)) |_| return "fv1000" else |_| {}
        }
        if (bio.jpx.isPath(path)) {
            if (bio.jpx.readMetadataPath(self.allocator, self.io, path)) |_| return "jpx" else |_| {}
        }
        if (bio.hamamatsuvms.isPath(path)) {
            if (bio.hamamatsuvms.readMetadataPath(self.allocator, self.io, path)) |_| return "hamamatsuvms" else |_| {}
        }
        if (bio.zeisstiff.isPath(path)) {
            if (bio.zeisstiff.readMetadataPath(self.allocator, self.io, path)) |_| return "zeisstiff" else |_| {}
        }
        if (bio.pcoraw.isPath(path)) {
            if (bio.pcoraw.readMetadataPath(self.allocator, self.io, path)) |_| return "pcoraw" else |_| {}
        }
        if (bio.jpk.isPath(path)) {
            if (bio.jpk.readMetadataPath(self.allocator, self.io, path)) |_| return "jpk" else |_| {}
        }
        if (bio.imaristiff.isPath(path)) {
            if (bio.imaristiff.readMetadataPath(self.allocator, self.io, path)) |_| return "imaristiff" else |_| {}
        }
        if (bio.rcpnl.isPath(path)) {
            if (bio.rcpnl.readMetadataPath(self.allocator, self.io, path)) |_| return "rcpnl" else |_| {}
        }
        if (bio.ndpis.isPath(path)) {
            if (bio.ndpis.readMetadataPath(self.allocator, self.io, path)) |_| return "ndpis" else |_| {}
        }
        if (bio.perkinelmer.isPath(path)) {
            if (bio.perkinelmer.readMetadataPath(self.allocator, self.io, path)) |_| return "perkinelmer" else |_| {}
        }
        if (bio.spc.isPath(path)) {
            if (bio.spc.readMetadataPath(self.allocator, self.io, path)) |_| return "spc" else |_| {}
        }
        if (bio.xlef.isPath(path)) {
            if (bio.xlef.readMetadataPath(self.allocator, self.io, path)) |_| return "xlef" else |_| {}
        }
        return null;
    }

    fn probeCompanionFormat(self: *Server, path: []const u8) !?[]const u8 {
        if (bio.analyze.isPath(path)) {
            if (bio.analyze.readMetadataPath(self.allocator, self.io, path)) |_| return "analyze" else |_| {}
        }
        if (bio.pds.isPath(path)) {
            if (bio.pds.readMetadataPath(self.allocator, self.io, path)) |_| return "pds" else |_| {}
        }
        if (bio.ndpis.isPath(path)) {
            if (bio.ndpis.readMetadataPath(self.allocator, self.io, path)) |_| return "ndpis" else |_| {}
        }
        if (bio.inveon.isPath(path)) {
            if (bio.inveon.readMetadataPath(self.allocator, self.io, path)) |_| return "inveon" else |_| {}
        }
        if (bio.fuji.isPath(path)) {
            if (bio.fuji.readMetadataPath(self.allocator, self.io, path)) |_| return "fuji" else |_| {}
        }
        if (bio.hitachi.isPath(path)) {
            if (bio.hitachi.readMetadataPath(self.allocator, self.io, path)) |_| return "hitachi" else |_| {}
        }
        if (bio.imagic.isPath(path)) {
            if (bio.imagic.readMetadataPath(self.allocator, self.io, path)) |_| return "imagic" else |_| {}
        }
        if (bio.ics.isPath(path)) {
            if (bio.ics.readMetadataPath(self.allocator, self.io, path)) |_| return "ics" else |_| {}
        }
        if (bio.unisoku.isPath(path)) {
            if (bio.unisoku.readMetadataPath(self.allocator, self.io, path)) |_| return "unisoku" else |_| {}
        }
        return null;
    }

    fn readCompanionPlane(
        self: *Server,
        format: []const u8,
        path: []const u8,
        plane_index: u32,
        region: bio.Region,
    ) !bio.Plane {
        if (std.mem.eql(u8, format, "analyze")) {
            return bio.analyze.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "afi")) {
            return bio.afi.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "apl")) {
            return bio.apl.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "pds")) {
            return bio.pds.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "ndpis")) {
            return bio.ndpis.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "perkinelmer")) {
            return bio.perkinelmer.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "pcoraw")) {
            return bio.pcoraw.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "jpk")) {
            return bio.jpk.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "l2d")) {
            return bio.l2d.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "bdpathway")) {
            return bio.bdpathway.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "cellworx")) {
            return bio.cellworx.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "cellsens")) {
            return bio.cellsens.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "olympustile")) {
            return bio.olympustile.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "cellvoyager")) {
            return bio.cellvoyager.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "incell")) {
            return bio.incell.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "columbus")) {
            return bio.columbus.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "cv7000")) {
            return bio.cv7000.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "jdce")) {
            return bio.jdce.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "metaxpress")) {
            return bio.metaxpress.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "micromanager")) {
            return bio.micromanager.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "fake")) {
            return bio.fake.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "visitech")) {
            return bio.visitech.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "bruker")) {
            return bio.bruker.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "filepattern")) {
            return bio.filepattern.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "tecan")) {
            return bio.tecan.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "tillvision")) {
            return bio.tillvision.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "flex")) {
            return bio.flex.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "fv1000")) {
            return bio.fv1000.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "jpx")) {
            return bio.jpx.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "hamamatsuvms")) {
            return bio.hamamatsuvms.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "zeisstiff")) {
            return bio.zeisstiff.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "imaristiff")) {
            return bio.imaristiff.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "rcpnl")) {
            return bio.rcpnl.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "inveon")) {
            return bio.inveon.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "fuji")) {
            return bio.fuji.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "hitachi")) {
            return bio.hitachi.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "imagic")) {
            return bio.imagic.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "ics")) {
            return bio.ics.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "unisoku")) {
            return bio.unisoku.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "spc")) {
            return bio.spc.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        if (std.mem.eql(u8, format, "xlef")) {
            return bio.xlef.readPlanePathRegionIndex(self.allocator, self.io, path, plane_index, region);
        }
        return error.UnsupportedFormat;
    }

    fn isPathBackedCompanion(handle: *const Handle) bool {
        return isCompanionFormat(handle.metadata.format) and !std.mem.eql(u8, handle.path, "<inline>");
    }

    fn isCompanionFormat(format: []const u8) bool {
        return std.mem.eql(u8, format, "analyze") or
            std.mem.eql(u8, format, "afi") or
            std.mem.eql(u8, format, "apl") or
            std.mem.eql(u8, format, "pds") or
            std.mem.eql(u8, format, "ndpis") or
            std.mem.eql(u8, format, "perkinelmer") or
            std.mem.eql(u8, format, "pcoraw") or
            std.mem.eql(u8, format, "jpk") or
            std.mem.eql(u8, format, "l2d") or
            std.mem.eql(u8, format, "bdpathway") or
            std.mem.eql(u8, format, "cellworx") or
            std.mem.eql(u8, format, "cellsens") or
            std.mem.eql(u8, format, "olympustile") or
            std.mem.eql(u8, format, "cellvoyager") or
            std.mem.eql(u8, format, "incell") or
            std.mem.eql(u8, format, "columbus") or
            std.mem.eql(u8, format, "cv7000") or
            std.mem.eql(u8, format, "jdce") or
            std.mem.eql(u8, format, "metaxpress") or
            std.mem.eql(u8, format, "micromanager") or
            std.mem.eql(u8, format, "fake") or
            std.mem.eql(u8, format, "visitech") or
            std.mem.eql(u8, format, "bruker") or
            std.mem.eql(u8, format, "filepattern") or
            std.mem.eql(u8, format, "tecan") or
            std.mem.eql(u8, format, "tillvision") or
            std.mem.eql(u8, format, "flex") or
            std.mem.eql(u8, format, "fv1000") or
            std.mem.eql(u8, format, "jpx") or
            std.mem.eql(u8, format, "hamamatsuvms") or
            std.mem.eql(u8, format, "zeisstiff") or
            std.mem.eql(u8, format, "imaristiff") or
            std.mem.eql(u8, format, "rcpnl") or
            std.mem.eql(u8, format, "inveon") or
            std.mem.eql(u8, format, "fuji") or
            std.mem.eql(u8, format, "hitachi") or
            std.mem.eql(u8, format, "imagic") or
            std.mem.eql(u8, format, "ics") or
            std.mem.eql(u8, format, "unisoku") or
            std.mem.eql(u8, format, "spc") or
            std.mem.eql(u8, format, "xlef");
    }
};

pub fn handleLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    line: []const u8,
    writer: *std.Io.Writer,
) !bool {
    var server = Server.init(allocator, io);
    defer server.deinit();
    return server.handleLine(line, writer);
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_image_bytes));
}

fn requiresObjectParams(method: []const u8) bool {
    return std.mem.eql(u8, method, "probe") or
        std.mem.eql(u8, method, "open") or
        std.mem.eql(u8, method, "close") or
        std.mem.eql(u8, method, "metadata") or
        std.mem.eql(u8, method, "readPlane");
}

fn hasMultipleInputSources(params: ?std.json.Value) bool {
    const value = params orelse return false;
    if (value != .object) return false;
    var count: u8 = 0;
    if (value.object.get("path") != null) count += 1;
    if (value.object.get("handle") != null) count += 1;
    if (value.object.get("data") != null) count += 1;
    return count > 1;
}

const PathParam = union(enum) {
    missing,
    invalid,
    value: []const u8,
};

fn getPathParam(params: ?std.json.Value) PathParam {
    const value = params orelse return .missing;
    if (value != .object) return .missing;
    const path = value.object.get("path") orelse return .missing;
    if (path != .string) return .invalid;
    if (path.string.len == 0) return .invalid;
    return .{ .value = path.string };
}

const DataParam = union(enum) {
    missing,
    invalid,
    value: []u8,
};

fn getDataParam(allocator: std.mem.Allocator, params: ?std.json.Value) !DataParam {
    const value = params orelse return .missing;
    if (value != .object) return .missing;
    const data = value.object.get("data") orelse return .missing;
    if (data != .string) return .invalid;
    if (data.string.len == 0) return .invalid;
    const bytes = decodeInlineData(allocator, data.string) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .invalid,
    };
    return .{ .value = bytes };
}

fn decodeInlineData(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const max_len = decoder.calcSizeUpperBound(encoded.len);
    if (max_len > max_image_bytes) return error.InvalidData;
    const scratch = try allocator.alloc(u8, max_len);
    defer allocator.free(scratch);
    const len = decoder.decode(scratch, encoded) catch return error.InvalidData;
    const out = try allocator.alloc(u8, len);
    @memcpy(out, scratch[0..len]);
    return out;
}

fn isValidRequestId(id: std.json.Value) bool {
    return switch (id) {
        .null, .integer, .float, .number_string, .string => true,
        else => false,
    };
}

fn getHandleId(params: ?std.json.Value) ?u64 {
    return switch (getHandleParam(params)) {
        .value => |id| id,
        else => null,
    };
}

const HandleParam = union(enum) {
    missing,
    invalid,
    value: u64,
};

fn getHandleParam(params: ?std.json.Value) HandleParam {
    const value = params orelse return .missing;
    if (value != .object) return .missing;
    const handle = value.object.get("handle") orelse return .missing;
    return switch (handle) {
        .integer => |id| if (id >= 0) .{ .value = @intCast(id) } else .invalid,
        else => .invalid,
    };
}

fn getPlaneIndex(params: ?std.json.Value, metadata: bio.Metadata) !u32 {
    const value = params orelse return 0;
    if (value != .object) return 0;
    const has_plane_index = value.object.get("planeIndex") != null;
    const has_zct = value.object.get("z") != null or value.object.get("c") != null or value.object.get("t") != null;
    if (has_plane_index and has_zct) return error.InvalidPlaneIndex;
    if (value.object.get("planeIndex")) |plane_index| {
        return switch (plane_index) {
            .integer => |index| if (index >= 0 and index <= std.math.maxInt(u32)) @intCast(index) else error.InvalidPlaneIndex,
            else => error.InvalidPlaneIndex,
        };
    }
    if (!has_zct) return 0;
    const z = try getU32OrDefault(value.object.get("z"), 0);
    const c = try getU32OrDefault(value.object.get("c"), 0);
    const t = try getU32OrDefault(value.object.get("t"), 0);
    return metadata.planeIndex(z, c, t);
}

fn getU32OrDefault(value: ?std.json.Value, default: u32) !u32 {
    const item = value orelse return default;
    return switch (item) {
        .integer => |index| if (index >= 0 and index <= std.math.maxInt(u32)) @intCast(index) else error.InvalidPlaneIndex,
        else => error.InvalidPlaneIndex,
    };
}

fn getRegion(params: ?std.json.Value, metadata: bio.Metadata) !bio.Region {
    const full = bio.Region.full(metadata);
    const value = params orelse return full;
    if (value != .object) return full;
    const x = try getRegionU32OrDefault(value.object.get("x"), 0);
    const y = try getRegionU32OrDefault(value.object.get("y"), 0);
    if (x > metadata.width or y > metadata.height) return error.InvalidRegion;
    const width = try getRegionU32OrDefault(value.object.get("width"), metadata.width - x);
    const height = try getRegionU32OrDefault(value.object.get("height"), metadata.height - y);
    if (width == 0 or height == 0) return error.InvalidRegion;
    if (width > metadata.width - x or height > metadata.height - y) return error.InvalidRegion;
    return .{ .x = x, .y = y, .width = width, .height = height };
}

fn getRegionU32OrDefault(value: ?std.json.Value, default: u32) !u32 {
    const item = value orelse return default;
    return switch (item) {
        .integer => |integer| if (integer >= 0 and integer <= std.math.maxInt(u32)) @intCast(integer) else error.InvalidRegion,
        else => error.InvalidRegion,
    };
}

fn beginResult(writer: *std.Io.Writer, id: std.json.Value) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJson(writer, id);
    try writer.writeAll(",\"result\":");
}

fn endMessage(writer: *std.Io.Writer) !void {
    try writer.writeByte('}');
}

fn writeInitialize(writer: *std.Io.Writer, id: std.json.Value) !void {
    try beginResult(writer, id);
    try writer.writeAll(
        \\{"server":"bioformats-zig","protocol":"json-rpc-2.0-line-delimited","methods":["initialize","formats","probe","open","close","metadata","readPlane","shutdown"],"capabilities":{"metadata":true,"pixels":true,"handles":true,"batch":true,"notifications":true,"planeEncoding":"base64","regions":true,"zctCoordinates":true,"inlineData":true}}
    );
    try endMessage(writer);
}

fn writeFormats(writer: *std.Io.Writer, id: std.json.Value) !void {
    try beginResult(writer, id);
    try writer.writeByte('[');
    for (bio.formats, 0..) |format, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try writeJson(writer, format.id);
        try writer.writeAll(",\"name\":");
        try writeJson(writer, format.name);
        try writer.writeAll(",\"extensions\":[");
        for (format.extensions, 0..) |extension, j| {
            if (j != 0) try writer.writeByte(',');
            try writeJson(writer, extension);
        }
        try writer.writeAll("],\"canReadPixels\":");
        try writer.writeAll(if (format.can_read_pixels) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    try endMessage(writer);
}

fn writeProbe(writer: *std.Io.Writer, id: std.json.Value, path: []const u8, bytes: []const u8) !void {
    try beginResult(writer, id);
    try writer.writeAll("{\"path\":");
    try writeJson(writer, path);
    try writer.writeAll(",\"matched\":");
    if (bio.detect(bytes)) |format| {
        try writer.writeAll("true,\"format\":");
        try writeJson(writer, format);
    } else {
        try writer.writeAll("false,\"format\":null");
    }
    try writer.writeByte('}');
    try endMessage(writer);
}

fn writeProbeFormat(writer: *std.Io.Writer, id: std.json.Value, path: []const u8, format: []const u8) !void {
    try beginResult(writer, id);
    try writer.writeAll("{\"path\":");
    try writeJson(writer, path);
    try writer.writeAll(",\"matched\":true,\"format\":");
    try writeJson(writer, format);
    try writer.writeByte('}');
    try endMessage(writer);
}

fn writePlane(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    id: std.json.Value,
    plane: bio.Plane,
    region: bio.Region,
) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(plane.data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, plane.data);

    try beginResult(writer, id);
    try writer.writeAll("{\"metadata\":");
    try writeMetadataObject(writer, plane.metadata);
    if (!region.isFull(plane.metadata)) {
        try writer.print(",\"region\":{{\"x\":{},\"y\":{},\"width\":{},\"height\":{}}}", .{
            region.x,
            region.y,
            region.width,
            region.height,
        });
    }
    try writer.writeAll(",\"encoding\":\"base64\",\"data\":");
    try writeJson(writer, encoded);
    try writer.writeByte('}');
    try endMessage(writer);
}

fn writeMetadataObject(writer: *std.Io.Writer, metadata: bio.Metadata) !void {
    try writer.print(
        "{{\"format\":\"{s}\",\"width\":{},\"height\":{},\"sizeC\":{},\"sizeZ\":{},\"sizeT\":{},\"pixelType\":\"{s}\",\"littleEndian\":{},\"planeCount\":{},\"samplesPerPixel\":{}",
        .{
            metadata.format,
            metadata.width,
            metadata.height,
            metadata.size_c,
            metadata.size_z,
            metadata.size_t,
            metadata.pixel_type.name(),
            metadata.little_endian,
            metadata.plane_count,
            if (metadata.samples_per_pixel == 0) metadata.size_c else metadata.samples_per_pixel,
        },
    );
    if (metadata.dimension_order) |dimension_order| {
        try writer.writeAll(",\"dimensionOrder\":");
        try writeJson(writer, dimension_order);
    }
    if (metadata.image_description) |description| {
        try writer.writeAll(",\"imageDescription\":");
        try writeJson(writer, description);
    }
    try writer.writeByte('}');
}

fn writeReaderError(writer: *std.Io.Writer, id: std.json.Value, err: anyerror) !void {
    const message = switch (err) {
        error.UnsupportedFormat => "Unsupported format",
        error.InvalidFormat => "Invalid format",
        error.InvalidPlaneIndex => "Invalid plane index",
        error.InvalidRegion => "Invalid plane region",
        error.UnsupportedVariant => "Unsupported format variant",
        error.TruncatedData => "Truncated data",
        error.FileNotFound => "File not found",
        error.AccessDenied, error.PermissionDenied => "Access denied",
        error.StreamTooLong => "File exceeds maximum supported size",
        else => "I/O or reader error",
    };
    try writeError(writer, id, -32000, message);
}

fn writeError(writer: *std.Io.Writer, id: std.json.Value, code: i32, message: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJson(writer, id);
    try writer.print(",\"error\":{{\"code\":{},\"message\":", .{code});
    try writeJson(writer, message);
    try writer.writeAll("}}");
}

fn writeJson(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "initialize response is json-rpc" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeInitialize(&out.writer, .{ .integer = 1 });
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "{\"jsonrpc\":\"2.0\""));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "}"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"planeEncoding\":\"base64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"regions\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"zctCoordinates\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"inlineData\":true") != null);
}

test "server handles json-rpc batch requests" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"formats\"}]",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "[{\"jsonrpc\":\"2.0\",\"id\":1"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":2,\"result\":[") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "}]\n"));
}

test "server handles invalid json-rpc batch entries" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "[1,{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"unknown\"}]",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":null,\"error\":{\"code\":-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":2,\"error\":{\"code\":-32601") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "]\n"));
}

test "server rejects missing json-rpc version" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"id\":1,\"method\":\"initialize\"}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600,\"message\":\"Invalid JSON-RPC version\"}}\n", out.written());
}

test "server rejects invalid json-rpc version in batch" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "[{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"initialize\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"formats\"}]",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "[{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32600"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":2,\"result\":[") != null);
}

test "server reports invalid no-id request object" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"method\":\"initialize\"}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid JSON-RPC version\"}}\n", out.written());
}

test "server includes invalid no-id objects but omits notifications from batch" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "[{\"method\":\"initialize\"},{\"jsonrpc\":\"2.0\",\"method\":\"formats\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\"}]",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "[{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":2,\"result\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":null,\"result\"") == null);
}

test "server rejects invalid request id type" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":{\"bad\":1},\"method\":\"initialize\"}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid id\"}}\n", out.written());
}

test "server rejects invalid request id type in batch" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "[{\"jsonrpc\":\"2.0\",\"id\":[],\"method\":\"initialize\"},{\"jsonrpc\":\"2.0\",\"id\":\"ok\",\"method\":\"initialize\"}]",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "[{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid id\"}"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"ok\",\"result\":") != null);
}

test "server omits response for notification" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"method\":\"formats\"}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expectEqualStrings("", out.written());
}

test "server omits notifications from batch response" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "[{\"jsonrpc\":\"2.0\",\"method\":\"formats\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\"}]",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "[{\"jsonrpc\":\"2.0\",\"id\":2"));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "}]\n"));
}

test "server notification close releases handle without response" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    const path = try std.testing.allocator.dupe(u8, "memory.ppm");
    const bytes = try std.testing.allocator.dupe(u8, "P6\n1 1\n255\n" ++ [_]u8{ 1, 2, 3 });
    const metadata = try bio.readMetadata(bytes);
    try server.handles.append(std.testing.allocator, .{
        .id = 9,
        .path = path,
        .bytes = bytes,
        .metadata = metadata,
    });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"method\":\"close\",\"params\":{\"handle\":9}}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expectEqual(@as(usize, 0), server.handles.items.len);
    try std.testing.expectEqualStrings("", out.written());
}

test "server notification shutdown has no response" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"method\":\"shutdown\"}",
        &out.writer,
    );

    try std.testing.expect(should_shutdown);
    try std.testing.expectEqualStrings("", out.written());
}

test "formats response includes expanded readers" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeFormats(&out.writer, .{ .integer = 1 });

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"aim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"alicona\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"amira\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"analyze\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"arf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"avi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"biorad\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"bioradgel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"bioradscn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"bdpathway\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"burleigh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"cellomics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"dng\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"dicom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"ecat7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"eps\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"fei\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"feitiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"fits\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"fluoview\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"fuji\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"gatandm2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"gel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"gif\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"his\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"hitachi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"hrdgdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"i2i\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"imacon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"imagic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"ics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"imod\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"imaristiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"improvisiontiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"inr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"inveon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"ionpathmibi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"iplab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"jeol\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"jpk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"khoros\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"kodak\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"leo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"liflim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"lim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"metamorph\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"mias\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"microct\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"mikroscan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"molecularimaging\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"mrc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"nifti\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"ndpis\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"nikonelements\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"nikontiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"nrrd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"omexml\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"ometiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"openlabraw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"oxfordinstruments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"pcx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"pcoraw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"pds\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"photoshoptiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"pqbin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"povray\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"pyramidtiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"quesant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"rcpnl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"rhk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"sbig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"seiko\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"seq\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"sif\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"simplepci\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"sis\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"slidebooktiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"spider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"spe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"smcamera\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"svs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"tga\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"topometrix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"trestle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"ubm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"unisoku\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"varianfdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"vectra\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"ventana\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"vgsam\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"watop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"zeisslms\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"zeisslsm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"pam\"") != null);
}

test "server opens and closes handles" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    const path = try std.testing.allocator.dupe(u8, "memory.ppm");
    const bytes = try std.testing.allocator.dupe(u8, "P6\n1 1\n255\n" ++ [_]u8{ 1, 2, 3 });
    const metadata = try bio.readMetadata(bytes);
    try server.handles.append(std.testing.allocator, .{
        .id = 7,
        .path = path,
        .bytes = bytes,
        .metadata = metadata,
    });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"handle\":7}", .{});
    defer parsed.deinit();
    try server.closeHandle(&out.writer, .{ .integer = 1 }, parsed.value);
    try std.testing.expectEqual(@as(usize, 0), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":true") != null);
}

test "server opens path and reads through returned handle" {
    const file_path = "protocol-open-handle-test.ppm";
    const data = "P6\n1 1\n255\n" ++ [_]u8{ 1, 2, 3 };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-open-handle-test.ppm\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"handle\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"netpbm\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AQID\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"close\",\"params\":{\"handle\":1}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 0), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"result\":true") != null);
}

test "server opens analyze img path and reads companion pixels" {
    const hdr_path = "protocol-analyze-test.hdr";
    const img_path = "protocol-analyze-test.img";
    var header = [_]u8{0} ** 348;
    std.mem.writeInt(i32, header[0..4], 348, .little);
    std.mem.writeInt(u16, header[40..42], 4, .little);
    std.mem.writeInt(u16, header[42..44], 2, .little);
    std.mem.writeInt(u16, header[44..46], 2, .little);
    std.mem.writeInt(u16, header[46..48], 1, .little);
    std.mem.writeInt(u16, header[48..50], 1, .little);
    std.mem.writeInt(u16, header[70..72], 4, .little);
    std.mem.writeInt(u32, header[108..112], @bitCast(@as(f32, 0)), .little);
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hdr_path, .data = &header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hdr_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = img_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, img_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-analyze-test.img\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"analyze\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1,\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":1,\"y\":0,\"width\":1,\"height\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AgAEAA==\"") != null);
}

test "server opens pds img path and reads companion pixels" {
    const hdr_path = "protocol-pds-test.hdr";
    const img_path = "protocol-pds-test.img";
    const header =
        " IDENTIFICATION\r\n" ++
        "NXP=2\r\n" ++
        "NYP=2\r\n" ++
        "COLOR=1\r\n" ++
        "FILE REC LEN=4\r\n";
    const pixels = [_]u8{
        1,    0,    2,    0,
        0xff, 0xff, 0xff, 0xff,
        3,    0,    4,    0,
        0xff, 0xff, 0xff, 0xff,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hdr_path, .data = header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hdr_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = img_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, img_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-pds-test.img\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"pds\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1,\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":1,\"y\":0,\"width\":1,\"height\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AgAEAA==\"") != null);
}

test "server opens ndpis sidecar and reads first ndpi pixels" {
    const sidecar_path = "protocol-ndpis-test.ndpis";
    const image_path = "protocol-ndpis-test-0.ndpi";
    const sidecar = "NoImages=1\r\nImage0=protocol-ndpis-test-0.ndpi\r\n";
    const image = [_]u8{
        'I', 'I', 42,  0,   8,   0,   0,   0,
        10,  0,   0,   1,   4,   0,   1,   0,
        0,   0,   1,   0,   0,   0,   1,   1,
        4,   0,   1,   0,   0,   0,   1,   0,
        0,   0,   2,   1,   3,   0,   1,   0,
        0,   0,   8,   0,   0,   0,   3,   1,
        3,   0,   1,   0,   0,   0,   1,   0,
        0,   0,   6,   1,   3,   0,   1,   0,
        0,   0,   1,   0,   0,   0,   17,  1,
        4,   0,   1,   0,   0,   0,   146, 0,
        0,   0,   21,  1,   3,   0,   1,   0,
        0,   0,   1,   0,   0,   0,   22,  1,
        4,   0,   1,   0,   0,   0,   1,   0,
        0,   0,   23,  1,   4,   0,   1,   0,
        0,   0,   1,   0,   0,   0,   146, 255,
        2,   0,   12,  0,   0,   0,   134, 0,
        0,   0,   0,   0,   0,   0,   'N', 'D',
        'P', 'I', '_', 'M', 'A', 'R', 'K', 'E',
        'R', 0,   77,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = sidecar_path, .data = sidecar });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, sidecar_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &image });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-ndpis-test.ndpis\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"ndpis\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"TQ==\"") != null);
}

test "server opens pcoraw rec path and reads tiff pixels" {
    const rec_path = "protocol-pcoraw-test.rec";
    const image_path = "protocol-pcoraw-test.pcoraw";
    const image = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0,   0,
        9,   0,   0,  1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 1,   1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   2,  1, 3, 0, 1,   0,
        0,   0,   8,  0, 0, 0, 3,   1,
        3,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   6,  1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 17,  1,
        4,   0,   1,  0, 0, 0, 122, 0,
        0,   0,   21, 1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 22,  1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   23, 1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 0,   0,
        0,   0,   77,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rec_path, .data = "Exposure / Delay: 10 ms\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, rec_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = image_path, .data = &image });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, image_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-pcoraw-test.rec\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"pcoraw\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"TQ==\"") != null);
}

test "server probes and opens jpk path through tiff delegate" {
    const file_path = "protocol-jpk-test.jpk";
    const image = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0,   0,
        9,   0,   0,  1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 1,   1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   2,  1, 3, 0, 1,   0,
        0,   0,   8,  0, 0, 0, 3,   1,
        3,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   6,  1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 17,  1,
        4,   0,   1,  0, 0, 0, 122, 0,
        0,   0,   21, 1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 22,  1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   23, 1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 0,   0,
        0,   0,   77,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = &image });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"probe\",\"params\":{\"path\":\"protocol-jpk-test.jpk\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"jpk\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"path\":\"protocol-jpk-test.jpk\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"jpk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"TQ==\"") != null);
}

test "server probes imaris tiff ims path before raw imaris" {
    const file_path = "protocol-imaristiff-test.ims";
    const image = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0,   0,
        9,   0,   0,  1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 1,   1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   2,  1, 3, 0, 1,   0,
        0,   0,   8,  0, 0, 0, 3,   1,
        3,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   6,  1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 17,  1,
        4,   0,   1,  0, 0, 0, 122, 0,
        0,   0,   21, 1, 3, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 22,  1,
        4,   0,   1,  0, 0, 0, 1,   0,
        0,   0,   23, 1, 4, 0, 1,   0,
        0,   0,   1,  0, 0, 0, 0,   0,
        0,   0,   77,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = &image });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"probe\",\"params\":{\"path\":\"protocol-imaristiff-test.ims\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"imaristiff\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"path\":\"protocol-imaristiff-test.ims\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"imaristiff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"TQ==\"") != null);
}

test "server opens rcpnl path as deltavision variant" {
    const file_path = "protocol-rcpnl-test.rcpnl";
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(std.testing.allocator);
    try data.appendNTimes(std.testing.allocator, 0, 1024);
    std.mem.writeInt(i32, data.items[0..4], 2, .little);
    std.mem.writeInt(i32, data.items[4..8], 2, .little);
    std.mem.writeInt(i32, data.items[8..12], 1, .little);
    std.mem.writeInt(i32, data.items[12..16], 6, .little);
    std.mem.writeInt(i16, data.items[96..98], -16224, .little);
    std.mem.writeInt(u16, data.items[180..182], 1, .little);
    std.mem.writeInt(u16, data.items[182..184], 0, .little);
    std.mem.writeInt(u16, data.items[196..198], 1, .little);
    try data.appendSlice(std.testing.allocator, &.{
        1, 0, 2, 0,
        3, 0, 4, 0,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data.items });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"probe\",\"params\":{\"path\":\"protocol-rcpnl-test.rcpnl\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"rcpnl\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"path\":\"protocol-rcpnl-test.rcpnl\",\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"rcpnl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"BAACAA==\"") != null);
}

test "server opens fuji img path and reads companion pixels" {
    const inf_path = "protocol-fuji-test.inf";
    const img_path = "protocol-fuji-test.img";
    const inf =
        "unused\n" ++
        "Sample\n" ++
        "unused\n" ++
        "0\n" ++
        "0\n" ++
        "16\n" ++
        "2\n" ++
        "2\n";
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = inf_path, .data = inf });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, inf_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = img_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, img_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-fuji-test.img\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"fuji\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1,\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":1,\"y\":0,\"width\":1,\"height\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AgAEAA==\"") != null);
}

test "server opens hitachi txt path and reads companion bmp pixels" {
    const txt_path = "protocol-hitachi-test.txt";
    const bmp_path = "protocol-hitachi-test.bmp";
    const sidecar =
        "[SemImageFile]\n" ++
        "SampleName=Hitachi sample\n" ++
        "ImageName=protocol-hitachi-test.bmp\n";
    const bmp = [_]u8{
        'B', 'M', 70, 0,  0, 0, 0,  0,  0,  0,   54,  0,   0,  0,
        40,  0,   0,  0,  2, 0, 0,  0,  2,  0,   0,   0,   1,  0,
        24,  0,   0,  0,  0, 0, 16, 0,  0,  0,   0,   0,   0,  0,
        0,   0,   0,  0,  0, 0, 0,  0,  0,  0,   0,   0,   30, 20,
        10,  60,  50, 40, 0, 0, 90, 80, 70, 120, 110, 100, 0,  0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = txt_path, .data = sidecar });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, txt_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bmp_path, .data = &bmp });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, bmp_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-hitachi-test.txt\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"hitachi\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1,\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":1,\"y\":0,\"width\":1,\"height\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"ZG54KDI8\"") != null);
}

test "server opens imagic img path and reads companion pixels" {
    const hed_path = "protocol-imagic-test.hed";
    const img_path = "protocol-imagic-test.img";
    var header = [_]u8{0} ** 1024;
    std.mem.writeInt(u32, header[48..52], 2, .little);
    std.mem.writeInt(u32, header[52..56], 2, .little);
    @memcpy(header[56..60], "INTG");
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hed_path, .data = &header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hed_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = img_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, img_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-imagic-test.img\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"imagic\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1,\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":1,\"y\":0,\"width\":1,\"height\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AgAEAA==\"") != null);
}

test "server opens ics ids path and reads companion pixels" {
    const ics_path = "protocol-ics-test.ics";
    const ids_path = "protocol-ics-test.ids";
    const header =
        "ics_version\t1.0\n" ++
        "layout\torder\tbits\tx\ty\n" ++
        "layout\tsizes\t16\t2\t2\n" ++
        "representation\tformat\tinteger\n" ++
        "representation\tsign\tunsigned\n" ++
        "representation\tbyte_order\t1\t2\n" ++
        "end\n";
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ics_path, .data = header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ics_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ids_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ids_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-ics-test.ids\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"ics\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1,\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":1,\"y\":0,\"width\":1,\"height\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AgAEAA==\"") != null);
}

test "server opens inveon dat path and reads companion pixels" {
    const hdr_path = "protocol-inveon-test.dat.hdr";
    const dat_path = "protocol-inveon-test.dat";
    const header =
        "# Header file for data file\n" ++
        "file_name protocol-inveon-test.dat\n" ++
        "data_type 2\n" ++
        "x_dimension 2\n" ++
        "y_dimension 2\n" ++
        "z_dimension 1\n" ++
        "data_file_pointer 0\n";
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hdr_path, .data = header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hdr_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dat_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, dat_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-inveon-test.dat\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"inveon\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1,\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":1,\"y\":0,\"width\":1,\"height\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AgAEAA==\"") != null);
}

test "server opens unisoku dat path and reads companion pixels" {
    const hdr_path = "protocol-unisoku-test.HDR";
    const dat_path = "protocol-unisoku-test.DAT";
    const header =
        ":STM data\r" ++
        ":data volume(x*y)\r" ++
        "2 2\r" ++
        ":ascii flag; data type\r" ++
        "0 4\r";
    const pixels = [_]u8{
        1, 0, 2, 0,
        3, 0, 4, 0,
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = hdr_path, .data = header });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hdr_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dat_path, .data = &pixels });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, dat_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"path\":\"protocol-unisoku-test.DAT\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"unisoku\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1,\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":1,\"y\":0,\"width\":1,\"height\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AgAEAA==\"") != null);
}

test "server probes inline base64 data" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"probe\",\"params\":{\"data\":\"UDYKMSAxCjI1NQoBAgM=\"}}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"matched\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"netpbm\"") != null);
}

test "server returns metadata from inline base64 data" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"metadata\",\"params\":{\"data\":\"UDYKMSAxCjI1NQoBAgM=\"}}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"netpbm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"pixelType\":\"rgb8\"") != null);
}

test "server readPlane returns pixels from inline base64 data" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"readPlane\",\"params\":{\"data\":\"UDYKMSAxCjI1NQoBAgM=\"}}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"encoding\":\"base64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AQID\"") != null);
}

test "server opens inline base64 data and reads through returned handle" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"open\",\"params\":{\"data\":\"UDYKMSAxCjI1NQoBAgM=\"}}",
        &out.writer,
    );
    try std.testing.expectEqual(@as(usize, 1), server.handles.items.len);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"handle\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"path\":\"<inline>\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AQID\"") != null);
}

test "server readPlane handle returns base64 data" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    const data = "P7\nWIDTH 1\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n" ++ [_]u8{ 10, 20, 30, 40 };
    const path = try std.testing.allocator.dupe(u8, "memory.pam");
    const bytes = try std.testing.allocator.dupe(u8, data);
    const metadata = try bio.readMetadata(bytes);
    try server.handles.append(std.testing.allocator, .{
        .id = 7,
        .path = path,
        .bytes = bytes,
        .metadata = metadata,
    });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":7}}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"netpbm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"pixelType\":\"rgba8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"ChQeKA==\"") != null);
}

test "server readPlane handle returns cropped region" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    const data = "P5\n2 2\n255\n" ++ [_]u8{ 1, 2, 3, 4 };
    const path = try std.testing.allocator.dupe(u8, "memory.pgm");
    const bytes = try std.testing.allocator.dupe(u8, data);
    const metadata = try bio.readMetadata(bytes);
    try server.handles.append(std.testing.allocator, .{
        .id = 8,
        .path = path,
        .bytes = bytes,
        .metadata = metadata,
    });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"readPlane\",\"params\":{\"handle\":8,\"x\":1,\"y\":0,\"width\":1,\"height\":2}}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":1,\"y\":0,\"width\":1,\"height\":2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AgQ=\"") != null);
}

test "server readPlane path returns cropped region" {
    const file_path = "protocol-readplane-path-region-test.pgm";
    const data = "P5\n2 2\n255\n" ++ [_]u8{ 1, 2, 3, 4 };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = data });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, file_path) catch {};

    var server = Server.init(std.testing.allocator, std.testing.io);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"readPlane\",\"params\":{\"path\":\"protocol-readplane-path-region-test.pgm\",\"x\":0,\"y\":1,\"width\":2,\"height\":1}}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"region\":{\"x\":0,\"y\":1,\"width\":2,\"height\":1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"AwQ=\"") != null);
}

test "server readPlane handle returns indexed gif plane" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    const data = [_]u8{
        'G', 'I',  'F',  '8', '9',  'a',
        2,   0,    1,    0,   0x80, 0,
        0,   0,    0,    0,   255,  0,
        0,   0x2c, 0,    0,   0,    0,
        2,   0,    1,    0,   0,    2,
        2,   0x44, 0x0a, 0,   0x2c, 0,
        0,   0,    0,    2,   0,    1,
        0,   0,    2,    2,   0x0c, 0x0a,
        0,   0x3b,
    };
    const path = try std.testing.allocator.dupe(u8, "memory.gif");
    const bytes = try std.testing.allocator.dupe(u8, &data);
    const metadata = try bio.readMetadata(bytes);
    try server.handles.append(std.testing.allocator, .{
        .id = 9,
        .path = path,
        .bytes = bytes,
        .metadata = metadata,
    });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const should_shutdown = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"readPlane\",\"params\":{\"handle\":9,\"planeIndex\":1}}",
        &out.writer,
    );

    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"gif\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"planeCount\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"data\":\"/wAAAAAA\"") != null);
}

test "server rejects invalid handle parameter types" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"metadata\",\"params\":{\"handle\":\"7\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params.handle\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":-1}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params.handle\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"close\",\"params\":{\"handle\":null}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params.handle\"") != null);
}

test "server rejects invalid path parameter types" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"probe\",\"params\":{\"path\":7}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params.path\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"open\",\"params\":{\"path\":null}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params.path\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"metadata\",\"params\":{\"path\":false}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params.path\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"readPlane\",\"params\":{\"path\":[]}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params.path\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"probe\",\"params\":{\"path\":\"\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params.path\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"metadata\",\"params\":{\"data\":\"not base64\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params.data\"") != null);
}

test "server rejects non-object params for parameterized methods" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"probe\",\"params\":[]}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"metadata\",\"params\":\"bad\"}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"readPlane\",\"params\":false}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params\"") != null);
}

test "server rejects invalid readPlane numeric parameters" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    const data = "P5\n2 2\n255\n" ++ [_]u8{ 1, 2, 3, 4 };
    const path = try std.testing.allocator.dupe(u8, "memory.pgm");
    const bytes = try std.testing.allocator.dupe(u8, data);
    const metadata = try bio.readMetadata(bytes);
    try server.handles.append(std.testing.allocator, .{
        .id = 10,
        .path = path,
        .bytes = bytes,
        .metadata = metadata,
    });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"readPlane\",\"params\":{\"handle\":10,\"planeIndex\":\"0\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid plane index\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":10,\"z\":false}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid plane index\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"readPlane\",\"params\":{\"handle\":10,\"x\":\"1\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid plane region\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"readPlane\",\"params\":{\"handle\":10,\"width\":0}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid plane region\"") != null);
}

test "server rejects mixed plane addressing modes" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    const data = "P5\n1 1\n255\n" ++ [_]u8{1};
    const path = try std.testing.allocator.dupe(u8, "memory.pgm");
    const bytes = try std.testing.allocator.dupe(u8, data);
    const metadata = try bio.readMetadata(bytes);
    try server.handles.append(std.testing.allocator, .{
        .id = 11,
        .path = path,
        .bytes = bytes,
        .metadata = metadata,
    });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"readPlane\",\"params\":{\"handle\":11,\"planeIndex\":0,\"z\":0}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid plane index\"") != null);
}

test "server rejects mixed path and handle addressing" {
    var server = Server.init(std.testing.allocator, undefined);
    defer server.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"metadata\",\"params\":{\"handle\":1,\"path\":\"sample.pgm\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"readPlane\",\"params\":{\"handle\":1,\"path\":\"sample.pgm\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"open\",\"params\":{\"handle\":1,\"path\":\"sample.pgm\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"close\",\"params\":{\"handle\":1,\"path\":\"sample.pgm\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"readPlane\",\"params\":{\"path\":\"sample.pgm\",\"data\":\"UDYKMSAxCjI1NQoBAgM=\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params\"") != null);
    out.clearRetainingCapacity();

    _ = try server.handleLine(
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"metadata\",\"params\":{\"handle\":1,\"data\":\"UDYKMSAxCjI1NQoBAgM=\"}}",
        &out.writer,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"message\":\"Invalid params\"") != null);
}

test "crops plane region" {
    var plane_data = [_]u8{ 1, 2, 3, 4 };
    const plane = bio.Plane{
        .metadata = .{
            .format = "test",
            .width = 2,
            .height = 2,
            .size_c = 1,
            .pixel_type = .uint8,
        },
        .data = &plane_data,
    };
    const cropped = try bio.cropPlane(std.testing.allocator, plane, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(cropped);
    try std.testing.expectEqualSlices(u8, &.{ 2, 4 }, cropped);
}

test "crops 16-bit plane region" {
    var plane_data = [_]u8{ 1, 0, 2, 0, 3, 0, 4, 0 };
    const plane = bio.Plane{
        .metadata = .{
            .format = "test",
            .width = 2,
            .height = 2,
            .size_c = 1,
            .pixel_type = .uint16,
            .little_endian = true,
        },
        .data = &plane_data,
    };
    const cropped = try bio.cropPlane(std.testing.allocator, plane, .{ .x = 1, .y = 0, .width = 1, .height = 2 });
    defer std.testing.allocator.free(cropped);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 4, 0 }, cropped);
}

test "metadata json includes image description" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeMetadataObject(&out.writer, .{
        .format = "tiff",
        .width = 1,
        .height = 1,
        .size_c = 1,
        .pixel_type = .uint8,
        .image_description = "<OME/>",
    });

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"imageDescription\":\"<OME/>\"") != null);
}

test "metadata json includes ome dimensions and samples per pixel" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeMetadataObject(&out.writer, .{
        .format = "tiff",
        .width = 1,
        .height = 1,
        .size_c = 2,
        .samples_per_pixel = 1,
        .size_z = 4,
        .size_t = 3,
        .pixel_type = .uint8,
        .dimension_order = "XYZCT",
    });

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"sizeC\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"samplesPerPixel\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"dimensionOrder\":\"XYZCT\"") != null);
}
