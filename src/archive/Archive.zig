const Archive = @This();

const builtin = @import("builtin");
const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const logger = std.log.scoped(.archive);
const elf = std.elf;
const Elf = @import("../link/Elf/Object.zig");
const MachO = @import("../link/MachO/Object.zig");
const macho = std.macho;
const Coff = @import("../link/Coff/Object.zig");
const Bitcode = @import("../link/Bitcode/Object.zig");
const coff = std.coff;

const Allocator = std.mem.Allocator;

dir: fs.Dir,
file: fs.File,
name: []const u8,

// We need to differentiate between inferred and output archive type, as other ar
// programs "just handle" any valid archive for parsing, regarldess of what a
// user has specified - the user specification should only matter for writing
// archives.
inferred_archive_type: ArchiveType,
output_archive_type: ArchiveType,

files: std.ArrayListUnmanaged(ArchivedFile),
symbols: std.ArrayListUnmanaged(Symbol),

// Use it so we can easily lookup files indices when inserting!
// TODO: A trie is probably a lot better here
file_name_to_index: std.StringArrayHashMapUnmanaged(u64),

modifiers: Modifiers,

stat: fs.File.Stat,

pub const ArchiveType = enum {
    ambiguous,
    gnu,
    gnuthin,
    gnu64,
    bsd,
    darwin, // *mostly* like BSD, with some differences in limited contexts when writing for determinism reasons
    darwin64,
    coff, // (windows)

    pub fn getAlignment(self: ArchiveType) u32 {
        // See: https://github.com/llvm-mirror/llvm/blob/2c4ca6832fa6b306ee6a7010bfb80a3f2596f824/lib/Object/ArchiveWriter.cpp#L311
        return switch (self) {
            .ambiguous => unreachable,
            else => if (self.isBsdLike()) @as(u32, 8) else @as(u32, 2),
        };
    }

    pub fn getFileAlignment(self: ArchiveType) u32 {
        // In this context, bsd like archives get 2 byte alignment but darwin
        // stick to 8 byte alignment
        return switch (self) {
            .ambiguous => unreachable,
            else => if (self.isDarwin()) @as(u32, 8) else @as(u32, 2),
        };
    }

    pub fn isBsdLike(self: ArchiveType) bool {
        return switch (self) {
            .bsd, .darwin, .darwin64 => true,
            else => false,
        };
    }

    pub fn isDarwin(self: ArchiveType) bool {
        return switch (self) {
            .darwin, .darwin64 => true,
            else => false,
        };
    }
};

pub const Operation = enum {
    insert,
    delete,
    move,
    print_contents,
    quick_append,
    ranlib,
    print_names,
    extract,
    print_symbols,
};

// We seperate errors into two classes, "handled" and "unhandled".
// The reason for this is that "handled" errors log appropriate error
// messages at the point they are created, whereas unhandled errors do
// not so the caller will need to print appropriate error messages
// themselves (if needed at all).
pub const UnhandledError = ParseError || CriticalError;
pub const HandledError = IoError;

pub const ParseError = error{
    NotArchive,
    MalformedArchive,
    Overflow,
    InvalidCharacter,
};

pub const CriticalError = error{
    OutOfMemory,
    TODO,
};

pub const IoError = error{
    AccessDenied,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    InputOutput,
    IsDir,
    NotOpenForReading,
    InvalidHandle,
    OperationAborted,
    SystemResources,
    Unexpected,
    Unseekable,
    WouldBlock,
    EndOfStream,
    BadPathName,
    DeviceBusy,
    FileBusy,
    FileLocksNotSupported,
    FileNotFound,
    FileTooBig,
    InvalidUtf8,
    NameTooLong,
    NoDevice,
    NoSpaceLeft,
    NotDir,
    PathAlreadyExists,
    PipeBusy,
    ProcessFdQuotaExceeded,
    SharingViolation,
    SymLinkLoop,
    SystemFdQuotaExceeded,
};

// All archive files start with this magic string
pub const magic_string = "!<arch>\n";
pub const magic_thin = "!<thin>\n";

// GNU constants
pub const gnu_first_line_buffer_length = 60;
pub const gnu_string_table_seek_pos = magic_string.len + gnu_first_line_buffer_length;

// BSD constants
pub const bsd_name_length_signifier = "#1/";
pub const bsd_symdef_magic = "__.SYMDEF";
pub const bsd_symdef_64_magic = "__.SYMDEF_64";
pub const bsd_symdef_sorted_magic = "__.SYMDEF SORTED";

pub const bsd_symdef_longest_magic = std.math.max(std.math.max(bsd_symdef_magic.len, bsd_symdef_64_magic.len), bsd_symdef_sorted_magic.len);

pub const invalid_file_index = std.math.maxInt(u64);

// The format (unparsed) of the archive per-file header
// NOTE: The reality is more complex than this as different mechanisms
// have been devised for storing the names of files which exceed 16 byte!
pub const Header = extern struct {
    ar_name: [16]u8,
    ar_date: [12]u8,
    ar_uid: [6]u8,
    ar_gid: [6]u8,
    ar_mode: [8]u8,
    ar_size: [10]u8,
    ar_fmag: [2]u8,

    pub const format_string = "{s: <16}{: <12}{: <6}{: <6}{: <8}{: <10}`\n";
};

pub const Modifiers = extern struct {
    // Supress warning for file creation
    create: bool = false,
    // Only insert files with more recent timestamps than archive
    update_only: bool = false,
    use_real_timestamps_and_ids: bool = false,
    build_symbol_table: bool = true,
    sort_symbol_table: bool = false,
    verbose: bool = false,
};

pub const Contents = struct {
    bytes: []u8,
    length: u64,
    mode: u64,
    timestamp: u128, // file modified time
    uid: u32,
    gid: u32,

    // TODO: dellocation

    pub fn write(self: *const Contents, out_stream: anytype, stderr: anytype) !void {
        try out_stream.writeAll(self.bytes);
        _ = stderr;
    }
};

// An internal represantion of files being archived
pub const ArchivedFile = struct {
    name: []const u8,
    contents: Contents,

    const Self = @This();
};

pub const Symbol = struct {
    name: []const u8,
    file_index: u64,
};

// TODO: BSD symbol table interpretation is architecture dependent,
// is there a way we can interpret this? (will be needed for
// cross-compilation etc. could possibly take it as a spec?)
// Using harcoding this information here is a bit of a hacky
// workaround in the short term - even though it is part of
// the spec.
const IntType = i32;

// type of ranlib used depends on the archive storage format
fn Ranlib(comptime storage: type) type {
    return extern struct {
        ran_strx: storage, // offset of symbol name in symbol table
        ran_off: storage, // offset of file header in archive
    };
}

const ErrorContext = enum {
    accessing,
    creating,
    opening,
    reading,
    seeking,
};

pub fn printFileIoError(comptime context: ErrorContext, file_name: []const u8, err: IoError) void {
    const context_str = @tagName(context);

    switch (err) {
        error.AccessDenied => logger.err("Error " ++ context_str ++ " {s}, access denied.", .{file_name}),
        else => logger.err("Error " ++ context_str ++ " {s}.", .{file_name}),
    }
    return;
}

pub fn handleFileIoError(comptime context: ErrorContext, file_name: []const u8, err_result: anytype) @TypeOf(err_result) {
    // TODO: at some point switch on the errors to show more info!
    _ = err_result catch |err| printFileIoError(context, file_name, err);
    return err_result;
}

// These are the defaults llvm ar uses (excepting windows)
// https://github.com/llvm-mirror/llvm/blob/master/tools/llvm-ar/llvm-ar.cpp
pub fn getDefaultArchiveTypeFromHost() ArchiveType {
    if (builtin.os.tag.isDarwin()) return .darwin;
    switch (builtin.os.tag) {
        .windows => return .coff,
        else => return .gnu,
    }
}

pub fn create(
    dir: fs.Dir,
    file: fs.File,
    name: []const u8,
    output_archive_type: ArchiveType,
    modifiers: Modifiers,
) !Archive {
    return Archive{
        .dir = dir,
        .file = file,
        .name = name,
        .inferred_archive_type = .ambiguous,
        .output_archive_type = output_archive_type,
        .files = .{},
        .symbols = .{},
        .file_name_to_index = .{},
        .modifiers = modifiers,
        .stat = try file.stat(),
    };
}

const SymbolStringTableAndOffsets = struct {
    unpadded_symbol_table_length: i32,
    symbol_table: []u8,
    symbol_offsets: []i32,

    pub fn deinit(self: *const SymbolStringTableAndOffsets, allocator: Allocator) void {
        allocator.free(self.symbol_offsets);
        allocator.free(self.symbol_table);
    }
};

pub fn buildSymbolTable(
    self: *Archive,
    allocator: Allocator,
) !SymbolStringTableAndOffsets {
    var symbol_table_size: usize = 0;
    const symbol_offsets = try allocator.alloc(i32, self.symbols.items.len);
    errdefer allocator.free(symbol_offsets);

    for (self.symbols.items) |symbol, idx| {
        symbol_offsets[idx] = @intCast(i32, symbol_table_size);
        symbol_table_size += symbol.name.len + 1;
    }

    const unpadded_symbol_table_length = symbol_table_size;

    while (symbol_table_size % self.output_archive_type.getAlignment() != 0) {
        symbol_table_size += 1;
    }

    const symbol_table = try allocator.alloc(u8, symbol_table_size);
    symbol_table_size = 0;

    for (self.symbols.items) |symbol| {
        mem.copy(u8, symbol_table[symbol_table_size..(symbol.name.len + symbol_table_size)], symbol.name);
        symbol_table[symbol_table_size + symbol.name.len] = 0;
        symbol_table_size += symbol.name.len + 1;
    }

    while (symbol_table_size % self.output_archive_type.getAlignment() != 0) {
        symbol_table[symbol_table_size] = 0;
        symbol_table_size += 1;
    }

    const result: SymbolStringTableAndOffsets = .{
        .unpadded_symbol_table_length = @intCast(i32, unpadded_symbol_table_length),
        .symbol_table = symbol_table,
        .symbol_offsets = symbol_offsets,
    };
    return result;
}

// TODO: This needs to be integrated into the workflow
// used for parsing. (use same error handling workflow etc.)
/// Use same naming scheme for objects (as found elsewhere in the file).
pub fn finalize(self: *Archive, allocator: Allocator) !void {
    if (self.output_archive_type == .ambiguous) {
        // if output archive type is still ambiguous (none was inferred, and
        // none was set) then we need to infer it from the host platform!
        self.output_archive_type = getDefaultArchiveTypeFromHost();
    }

    // Overwrite all contents
    try self.file.seekTo(0);

    const writer = self.file.writer();
    try writer.writeAll(if (self.output_archive_type == .gnuthin) magic_thin else magic_string);

    const header_names = try allocator.alloc([16]u8, self.files.items.len);

    // Symbol sorting function
    const SortFn = struct {
        fn sorter(context: void, x: Symbol, y: Symbol) bool {
            _ = context;
            return std.mem.lessThan(u8, x.name, y.name);
        }
    };

    // Sort the symbols
    if (self.modifiers.sort_symbol_table) {
        std.sort.sort(Symbol, self.symbols.items, {}, SortFn.sorter);
    }

    // Calculate the offset of file independent of string table and symbol table itself.
    // It is basically magic size + file size from position 0

    const relative_file_offsets = try allocator.alloc(i32, self.files.items.len);
    defer allocator.free(relative_file_offsets);

    {
        var offset: u32 = 0;
        for (self.files.items) |file, idx| {
            relative_file_offsets[idx] = @intCast(i32, offset);
            offset += @intCast(u32, @sizeOf(Header) + file.contents.bytes.len);

            // BSD also keeps the name in its data section
            if (self.output_archive_type.isBsdLike()) {
                offset += @intCast(u32, file.name.len);

                // Add padding
                while (offset % self.output_archive_type.getAlignment() != 0) {
                    offset += 1;
                }
            }
        }
    }

    // Set the mtime of symbol table to now seconds in non-deterministic mode
    const symtab_time: u64 = (if (self.modifiers.use_real_timestamps_and_ids) @intCast(u64, std.time.milliTimestamp()) else 0) / 1000;

    switch (self.output_archive_type) {
        .gnu, .gnuthin, .gnu64 => {
            // GNU format: Create string table
            var string_table = std.ArrayList(u8).init(allocator);
            defer string_table.deinit();

            // Generate the complete string table
            for (self.files.items) |file, index| {
                const is_the_name_allowed = (file.name.len < 16) and (self.output_archive_type != .gnuthin);

                // If the file is small enough to fit in header, then just write it there
                // Otherwise, add it to string table and add a reference to its location
                const name = if (is_the_name_allowed) try mem.concat(allocator, u8, &.{ file.name, "/" }) else try std.fmt.allocPrint(allocator, "/{}", .{blk: {
                    // Get the position of the file in string table
                    const pos = string_table.items.len;

                    // Now add the file name to string table
                    try string_table.appendSlice(file.name);
                    try string_table.appendSlice("/\n");

                    break :blk pos;
                }});
                defer allocator.free(name);

                // Edit the header
                _ = try std.fmt.bufPrint(&(header_names[index]), "{s: <16}", .{name});
            }

            // Write the symbol table itself
            if (self.modifiers.build_symbol_table and self.symbols.items.len != 0) {
                const symbol_string_table_and_offsets = try self.buildSymbolTable(allocator);
                defer symbol_string_table_and_offsets.deinit(allocator);

                const symbol_table = symbol_string_table_and_offsets.symbol_table;

                const format = self.output_archive_type;
                const int_size: usize = if (format == .gnu64) @sizeOf(u64) else @sizeOf(u32);

                const symbol_table_size =
                    symbol_table.len + // The string of symbols
                    (self.symbols.items.len * int_size) + // Size of all symbol offsets
                    int_size; // Value denoting the length of symbol table

                const magic: []const u8 = if (format == .gnu64) "/SYM64/" else "/";

                try writer.print(Header.format_string, .{ magic, symtab_time, 0, 0, 0, symbol_table_size });

                if (format == .gnu64) {
                    try writer.writeIntBig(u64, @intCast(u64, self.symbols.items.len));
                } else {
                    try writer.writeIntBig(u32, @intCast(u32, self.symbols.items.len));
                }

                // magic_string.len == magic_thin.len, so its not a problem
                var offset_to_files = magic_string.len;
                // Size of symbol table itself
                offset_to_files += @sizeOf(Header) + symbol_table_size;

                // Add padding
                while (offset_to_files % self.output_archive_type.getAlignment() != 0) {
                    offset_to_files += 1;
                }

                // Size of string table
                if (string_table.items.len != 0) {
                    offset_to_files += @sizeOf(Header) + string_table.items.len;
                }

                // Add further padding
                while (offset_to_files % self.output_archive_type.getAlignment() != 0) {
                    offset_to_files += 1;
                }

                for (self.symbols.items) |symbol| {
                    if (format == .gnu64) {
                        try writer.writeIntBig(i64, relative_file_offsets[symbol.file_index] + @intCast(i64, offset_to_files));
                    } else {
                        try writer.writeIntBig(i32, relative_file_offsets[symbol.file_index] + @intCast(i32, offset_to_files));
                    }
                }

                try writer.writeAll(symbol_table);
            }

            // Write the string table itself
            {
                if (string_table.items.len != 0) {
                    while (string_table.items.len % self.output_archive_type.getAlignment() != 0)
                        try string_table.append('\n');
                    try writer.print("//{s}{: <10}`\n{s}", .{ " " ** 46, string_table.items.len, string_table.items });
                }
            }
        },
        .bsd, .darwin, .darwin64 => {
            // BSD format: Write the symbol table
            // In darwin if symbol table writing is enabled the expected behaviour
            // is that we write an empty symbol table!
            const write_symbol_table =
                self.modifiers.build_symbol_table and (self.symbols.items.len != 0 or self.output_archive_type != .bsd);
            if (write_symbol_table) {
                const symbol_string_table_and_offsets = try self.buildSymbolTable(allocator);
                defer symbol_string_table_and_offsets.deinit(allocator);

                const symbol_table = symbol_string_table_and_offsets.symbol_table;

                const format = self.output_archive_type;
                const int_size: usize = if (format == .darwin64) @sizeOf(u64) else @sizeOf(u32);

                const num_ranlib_bytes = self.symbols.items.len * @sizeOf(Ranlib(IntType));

                const symbol_table_size =
                    bsd_symdef_64_magic.len + // Length of name
                    int_size + // Int describing the size of ranlib
                    num_ranlib_bytes + // Size of ranlib structs
                    int_size + // Int describing size of symbol table's strings
                    symbol_table.len; // The lengths of strings themselves

                try writer.print(Header.format_string, .{ "#1/12", symtab_time, 0, 0, 0, symbol_table_size });

                const endian = builtin.cpu.arch.endian();

                if (format == .darwin64) {
                    try writer.writeAll(bsd_symdef_64_magic);
                    try writer.writeInt(u64, @intCast(u64, num_ranlib_bytes), endian);
                } else {
                    try writer.writeAll(bsd_symdef_magic ++ "\x00\x00\x00");
                    try writer.writeInt(u32, @intCast(u32, num_ranlib_bytes), endian);
                }

                const ranlibs = try allocator.alloc(Ranlib(IntType), self.symbols.items.len);
                defer allocator.free(ranlibs);

                var offset_to_files: usize = magic_string.len + @sizeOf(Header) + symbol_table_size;

                // Add padding
                while (offset_to_files % self.output_archive_type.getAlignment() != 0) {
                    offset_to_files += 1;
                }

                for (self.symbols.items) |symbol, idx| {
                    ranlibs[idx].ran_strx = symbol_string_table_and_offsets.symbol_offsets[idx];
                    ranlibs[idx].ran_off = relative_file_offsets[symbol.file_index] + @intCast(i32, offset_to_files);
                }

                try writer.writeAll(mem.sliceAsBytes(ranlibs));

                if (format == .darwin64) {
                    try writer.writeInt(u64, @intCast(u64, symbol_string_table_and_offsets.unpadded_symbol_table_length), endian);
                } else {
                    try writer.writeInt(u32, @intCast(u32, symbol_string_table_and_offsets.unpadded_symbol_table_length), endian);
                }

                try writer.writeAll(symbol_table);
            }
        },
        // This needs to be able to tell whatsupp.
        else => unreachable,
    }

    // Write the files
    for (self.files.items) |file, index| {
        var header_buffer: [@sizeOf(Header)]u8 = undefined;

        const file_length = file_length_calculation: {
            if (!self.output_archive_type.isBsdLike()) {
                break :file_length_calculation file.contents.length;
            } else {
                const file_pos = try self.file.getPos();
                var padding = (file_pos + header_buffer.len + file.name.len) % self.output_archive_type.getAlignment();
                padding = (self.output_archive_type.getAlignment() - padding) % self.output_archive_type.getAlignment();

                // BSD format: Just write the length of the name in header
                _ = try std.fmt.bufPrint(&(header_names[index]), "#1/{: <13}", .{file.name.len + padding});
                if (self.output_archive_type.isDarwin()) {
                    var file_padding = file.contents.length % self.output_archive_type.getFileAlignment();
                    file_padding = (self.output_archive_type.getFileAlignment() - file_padding) % self.output_archive_type.getFileAlignment();
                    break :file_length_calculation file.contents.length + file.name.len + padding + file_padding;
                } else {
                    break :file_length_calculation file.contents.length + file.name.len + padding;
                }
            }
        };

        _ = try std.fmt.bufPrint(
            &header_buffer,
            Header.format_string,
            .{ &header_names[index], file.contents.timestamp, file.contents.uid, file.contents.gid, file.contents.mode, file_length },
        );

        // TODO: handle errors
        _ = try writer.write(&header_buffer);

        // Write the name of the file in the data section
        if (self.output_archive_type.isBsdLike()) {
            try writer.writeAll(file.name);

            while ((try self.file.getPos()) % self.output_archive_type.getAlignment() != 0)
                try writer.writeByte(0);
        }

        if (self.output_archive_type != .gnuthin) {
            try file.contents.write(writer, null);

            while ((try self.file.getPos()) % self.output_archive_type.getFileAlignment() != 0)
                try writer.writeByte('\n');
        }
    }

    // Truncate the file size
    try self.file.setEndPos(try self.file.getPos());
}

pub fn deleteFiles(self: *Archive, file_names: [][]const u8) !void {
    // For the list of given file names, find the entry in self.files
    // and remove it from self.files.
    for (file_names) |file_name| {
        for (self.files.items) |file, index| {
            if (std.mem.eql(u8, file.name, file_name)) {
                // Remove all the symbols associated with the file
                // when file is deleted
                var idx: usize = 0;
                while (idx < self.symbols.items.len) {
                    const sym = self.symbols.items[idx];
                    if (sym.file_index == index) {
                        _ = self.symbols.orderedRemove(idx);
                        continue;
                    }
                    idx += 1;
                }

                // Reset the index for all future symbols
                for (self.symbols.items) |*sym| {
                    if (sym.file_index > index) {
                        sym.file_index -= 1;
                    }
                }

                _ = self.files.orderedRemove(index);
                break;
            }
        }
    }
}

pub fn extract(self: *Archive, file_names: [][]const u8) !void {
    if (self.inferred_archive_type == .gnuthin) {
        // TODO: better error
        return error.ExtractingFromThin;
    }

    for (self.files.items) |archived_file| {
        for (file_names) |file_name| {
            if (std.mem.eql(u8, archived_file.name, file_name)) {
                const file = try self.dir.createFile(archived_file.name, .{});
                defer file.close();

                try file.writeAll(archived_file.contents.bytes);
                break;
            }
        }
    }
}

pub fn insertFiles(self: *Archive, allocator: Allocator, file_names: [][]const u8) !void {
    for (file_names) |file_name| {
        // Open the file and read all of its contents
        const file = try self.dir.openFile(file_name, .{ .mode = .read_only });
        defer file.close();

        // We only need to do this because file stats don't include
        // guid and uid - maybe the right solution is to integrate that into
        // the std so we can call file.stat() on all platforms.
        var gid: u32 = 0;
        var uid: u32 = 0;
        var mtime: i128 = 0;
        var size: u64 = undefined;
        var mode: u64 = undefined;

        // FIXME: Currently windows doesnt support the Stat struct
        if (builtin.os.tag == .windows) {
            const file_stats = try file.stat();
            // Convert timestamp from ns to s
            mtime = file_stats.mtime;
            size = file_stats.size;
            mode = file_stats.mode;
        } else {
            const file_stats = try std.os.fstat(file.handle);

            gid = file_stats.gid;
            uid = file_stats.uid;
            const mtime_full = file_stats.mtime();
            mtime = mtime_full.tv_sec * std.time.ns_per_s + mtime_full.tv_nsec;
            size = @intCast(u64, file_stats.size);
            mode = file_stats.mode;
        }

        // Get the file magic
        var magic: [4]u8 = undefined;
        _ = try file.reader().read(&magic);

        try file.seekTo(0);

        if (self.modifiers.update_only) {
            // TODO: Write a test that checks for this functionality still working!
            if (self.stat.mtime >= mtime) {
                continue;
            }
        }

        if (!self.modifiers.use_real_timestamps_and_ids) {
            gid = 0;
            uid = 0;
            mtime = 0;
            // Even though it's not documented - in deterministic mode permissions are always set to:
            // https://github.com/llvm-mirror/llvm/blob/2c4ca6832fa6b306ee6a7010bfb80a3f2596f824/include/llvm/Object/ArchiveWriter.h#L27
            // https://github.com/llvm-mirror/llvm/blob/2c4ca6832fa6b306ee6a7010bfb80a3f2596f824/lib/Object/ArchiveWriter.cpp#L105
            mode = 644;
        }

        const timestamp = @intCast(u128, @divFloor(mtime, std.time.ns_per_s));

        var archived_file = ArchivedFile{
            .name = try allocator.dupe(u8, fs.path.basename(file_name)),
            .contents = Contents{
                .bytes = try file.readToEndAlloc(allocator, std.math.maxInt(usize)),
                .length = size,
                .mode = mode,
                .timestamp = timestamp,
                .gid = gid,
                .uid = uid,
            },
        };

        const file_index = if (self.file_name_to_index.get(file_name)) |file_id| file_id else self.files.items.len;

        // Read symbols
        if (self.modifiers.build_symbol_table) {
            try file.seekTo(0);
            blk: {
                // TODO: Load object from memory (upstream zld)
                // TODO(TRC):Now this should assert that the magic number is what we expect it to be
                // based on the parsed archive type! Not inferring what we should do based on it.
                // switch(self.output_archive_type)
                // {

                // }
                if (mem.eql(u8, magic[0..Elf.magic.len], Elf.magic)) {
                    if (self.output_archive_type == .ambiguous) {
                        // TODO: double check that this is the correct inference
                        self.output_archive_type = .gnu;
                    }
                    var elf_file = Elf{ .file = file, .name = file_name };
                    defer elf_file.deinit(allocator);

                    // TODO: Do not use builtin.target like this, be more flexible!
                    elf_file.parse(allocator, builtin.target) catch |err| switch (err) {
                        error.NotObject => break :blk,
                        else => |e| return e,
                    };

                    for (elf_file.symtab.items) |sym| {
                        switch (sym.st_info >> 4) {
                            elf.STB_WEAK, elf.STB_GLOBAL => {
                                if (!(elf.SHN_LORESERVE <= sym.st_shndx and sym.st_shndx < elf.SHN_HIRESERVE and sym.st_shndx == elf.SHN_UNDEF)) {
                                    const symbol = Symbol{
                                        .name = try allocator.dupe(u8, elf_file.getString(sym.st_name)),
                                        .file_index = file_index,
                                    };
                                    try self.symbols.append(allocator, symbol);
                                }
                            },
                            else => {},
                        }
                    }
                } else if (mem.eql(u8, magic[0..Bitcode.magic.len], Bitcode.magic)) {
                    logger.warn("Zig ar does not currently support bitcode files, so no symbol table will be constructed for {s}.", .{file_name});
                    break :blk;

                    // var bitcode_file = Bitcode{ .file = file, .name = file_name };
                    // defer bitcode_file.deinit(allocator);

                    // // TODO: Do not use builtin.target like this, be more flexible!
                    // bitcode_file.parse(allocator, builtin.target) catch |err| switch (err) {
                    //     error.NotObject => break :blk,
                    //     else => |e| return e,
                    //};
                } else {
                    // TODO(TRC):Now this should assert that the magic number is what we expect it to be
                    // based on the parsed archive type! Not inferring what we should do based on it.
                    const magic_num = mem.readInt(u32, magic[0..], builtin.cpu.arch.endian());

                    if (magic_num == macho.MH_MAGIC or magic_num == macho.MH_MAGIC_64) {
                        if (self.output_archive_type == .ambiguous) {
                            self.output_archive_type = .darwin;
                        }
                        var macho_file = MachO{ .file = file, .name = file_name };
                        defer macho_file.deinit(allocator);

                        macho_file.parse(allocator, builtin.target) catch |err| switch (err) {
                            error.NotObject => break :blk,
                            else => |e| return e,
                        };

                        for (macho_file.symtab.items) |sym| {
                            if (sym.ext() and sym.sect()) {
                                const symbol = Symbol{
                                    .name = try allocator.dupe(u8, macho_file.getString(sym.n_strx)),
                                    .file_index = file_index,
                                };

                                try self.symbols.append(allocator, symbol);
                            }
                        }
                    } else if (false) {
                        // TODO: Figure out the condition under which a file is a coff
                        // file. This was originally just an else clause - but a file
                        // might not contain any symbols!
                        var coff_file = Coff{ .file = file, .name = file_name };
                        defer coff_file.deinit(allocator);

                        coff_file.parse(allocator, builtin.target) catch |err| return err;

                        for (coff_file.symtab.items) |sym| {
                            if (sym.storage_class == Coff.IMAGE_SYM_CLASS_EXTERNAL) {
                                const symbol = Symbol{
                                    .name = try allocator.dupe(u8, sym.getName(&coff_file)),
                                    .file_index = file_index,
                                };
                                try self.symbols.append(allocator, symbol);
                            }
                        }
                    }
                }
            }
        }

        // A trie-based datastructure would be better for this!
        const getOrPutResult = try self.file_name_to_index.getOrPut(allocator, archived_file.name);
        if (getOrPutResult.found_existing) {
            const existing_index = getOrPutResult.value_ptr.*;
            self.files.items[existing_index] = archived_file;
        } else {
            getOrPutResult.value_ptr.* = self.files.items.len;
            try self.files.append(allocator, archived_file);
        }
    }
}

pub fn parse(self: *Archive, allocator: Allocator) (ParseError || IoError || CriticalError)!void {
    const reader = self.file.reader();
    {
        // Is the magic header found at the start of the archive?
        var magic: [magic_string.len]u8 = undefined;
        const bytes_read = try handleFileIoError(.reading, self.name, reader.read(&magic));

        if (bytes_read == 0) {
            // Archive is empty and that is ok!
            return;
        }

        if (bytes_read < magic_string.len) {
            return ParseError.NotArchive;
        }

        const is_thin_archive = mem.eql(u8, &magic, magic_thin);

        if (is_thin_archive)
            self.inferred_archive_type = .gnuthin;

        if (!(mem.eql(u8, &magic, magic_string) or is_thin_archive)) {
            return ParseError.NotArchive;
        }
    }

    var gnu_symbol_table_contents: []u8 = undefined;
    var string_table_contents: []u8 = undefined;
    var has_gnu_symbol_table = false;
    {
        // https://www.freebsd.org/cgi/man.cgi?query=ar&sektion=5
        // Process string/symbol tables and/or try to infer archive type!
        var starting_seek_pos = magic_string.len;
        while (true) {
            var first_line_buffer: [gnu_first_line_buffer_length]u8 = undefined;

            const has_line_to_process = result: {
                const chars_read = try handleFileIoError(.reading, self.name, reader.read(&first_line_buffer));

                if (chars_read < first_line_buffer.len) {
                    break :result false;
                }

                break :result true;
            };

            if (!has_line_to_process) {
                try handleFileIoError(.seeking, self.name, reader.context.seekTo(starting_seek_pos));
                break;
            }

            if (mem.eql(u8, first_line_buffer[0..2], "//"[0..2])) {
                switch (self.inferred_archive_type) {
                    .ambiguous => self.inferred_archive_type = .gnu,
                    .gnu, .gnuthin, .gnu64 => {},
                    else => {
                        return ParseError.MalformedArchive;
                    },
                }

                const string_table_num_bytes_string = first_line_buffer[48..58];
                const string_table_num_bytes = try fmt.parseInt(u32, mem.trim(u8, string_table_num_bytes_string, " "), 10);

                string_table_contents = try allocator.alloc(u8, string_table_num_bytes);

                try handleFileIoError(.reading, self.name, reader.readNoEof(string_table_contents));
                break;
            } else if (!has_gnu_symbol_table and first_line_buffer[0] == '/') {
                has_gnu_symbol_table = true;
                switch (self.inferred_archive_type) {
                    .ambiguous => self.inferred_archive_type = .gnu,
                    .gnu, .gnuthin, .gnu64 => {},
                    else => {
                        return ParseError.MalformedArchive;
                    },
                }

                const symbol_table_num_bytes_string = first_line_buffer[48..58];
                const symbol_table_num_bytes = try fmt.parseInt(u32, mem.trim(u8, symbol_table_num_bytes_string, " "), 10);

                const num_symbols = try handleFileIoError(.reading, self.name, reader.readInt(u32, .Big));

                var num_bytes_remaining = symbol_table_num_bytes - @sizeOf(u32);

                const number_array = try allocator.alloc(u32, num_symbols);
                for (number_array) |_, number_index| {
                    number_array[number_index] = try handleFileIoError(.reading, self.name, reader.readInt(u32, .Big));
                }
                defer allocator.free(number_array);

                num_bytes_remaining = num_bytes_remaining - (@sizeOf(u32) * num_symbols);

                gnu_symbol_table_contents = try allocator.alloc(u8, num_bytes_remaining);

                const contents_read = try handleFileIoError(.reading, self.name, reader.read(gnu_symbol_table_contents));
                if (contents_read < gnu_symbol_table_contents.len) {
                    return ParseError.MalformedArchive;
                }

                var current_symbol_string = gnu_symbol_table_contents;
                var current_byte: u32 = 0;
                while (current_byte < gnu_symbol_table_contents.len) {
                    var symbol_length: u32 = 0;
                    var skip_length: u32 = 0;

                    var found_zero = false;
                    for (current_symbol_string) |byte| {
                        if (found_zero and byte != 0) {
                            break;
                        }

                        current_byte = current_byte + 1;

                        if (byte == 0) {
                            found_zero = true;
                        }

                        skip_length = skip_length + 1;

                        if (!found_zero) {
                            symbol_length = symbol_length + 1;
                        }
                    }

                    const symbol = Symbol{
                        .name = current_symbol_string[0..symbol_length],
                        // Note - we don't set the final file-index here,
                        // we recalculate and override that later in parsing
                        // when we know what they are!
                        .file_index = number_array[self.symbols.items.len],
                    };

                    try self.symbols.append(allocator, symbol);

                    current_symbol_string = current_symbol_string[skip_length..];
                }

                starting_seek_pos = starting_seek_pos + first_line_buffer.len + symbol_table_num_bytes;
            } else {
                try handleFileIoError(.seeking, self.name, reader.context.seekTo(starting_seek_pos));
                break;
            }
        }
    }

    var is_first = true;

    var file_offset_to_index: std.AutoArrayHashMapUnmanaged(u64, u64) = .{};
    defer file_offset_to_index.clearAndFree(allocator);

    while (true) {
        const file_offset = file_offset_result: {
            var current_file_offset = try handleFileIoError(.accessing, self.name, reader.context.getPos());
            // Archived files must start on even byte boundaries!
            // https://www.unix.com/man-page/opensolaris/3head/ar.h/
            if (@mod(current_file_offset, 2) == 1) {
                try handleFileIoError(.accessing, self.name, reader.skipBytes(1, .{}));
                current_file_offset = current_file_offset + 1;
            }
            break :file_offset_result current_file_offset;
        };

        const archive_header = reader.readStruct(Header) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                printFileIoError(.reading, self.name, err);
                return err;
            },
        };

        // the lifetime of the archive headers will matched that of the parsed files (for now)
        // so we can take a reference to the strings stored there directly!
        var trimmed_archive_name = mem.trim(u8, &archive_header.ar_name, " ");

        // Check against gnu naming properties
        const ends_with_gnu_slash = (trimmed_archive_name[trimmed_archive_name.len - 1] == '/');
        var gnu_offset_value: u32 = 0;
        const starts_with_gnu_offset = trimmed_archive_name[0] == '/';
        if (starts_with_gnu_offset) {
            gnu_offset_value = try fmt.parseInt(u32, trimmed_archive_name[1..trimmed_archive_name.len], 10);
        }

        const must_be_gnu = ends_with_gnu_slash or starts_with_gnu_offset or has_gnu_symbol_table;

        // TODO: if modifiers.use_real_timestamps_and_ids is disabled, do we ignore this from existing archive?
        // Check against llvm ar
        const timestamp = try fmt.parseInt(u128, mem.trim(u8, &archive_header.ar_date, " "), 10);
        const uid = try fmt.parseInt(u32, mem.trim(u8, &archive_header.ar_uid, " "), 10);
        const gid = try fmt.parseInt(u32, mem.trim(u8, &archive_header.ar_gid, " "), 10);

        // Check against bsd naming properties
        const starts_with_bsd_name_length = (trimmed_archive_name.len >= 2) and mem.eql(u8, trimmed_archive_name[0..2], bsd_name_length_signifier[0..2]);
        const could_be_bsd = starts_with_bsd_name_length;

        // TODO: Have a proper mechanism for erroring on the wrong types of archive.
        switch (self.inferred_archive_type) {
            .ambiguous => {
                if (must_be_gnu) {
                    self.inferred_archive_type = .gnu;
                } else if (could_be_bsd) {
                    self.inferred_archive_type = .bsd;
                } else {
                    return error.TODO;
                }
            },
            .gnu, .gnuthin, .gnu64 => {
                if (!must_be_gnu) {
                    return ParseError.MalformedArchive;
                }
            },
            .bsd, .darwin, .darwin64 => {
                if (must_be_gnu) {
                    return ParseError.MalformedArchive;
                }
            },
            else => {
                if (must_be_gnu) {
                    return error.TODO;
                }

                return error.TODO;
            },
        }

        if (ends_with_gnu_slash) {
            // slice-off the slash
            trimmed_archive_name = trimmed_archive_name[0 .. trimmed_archive_name.len - 1];
        }

        if (starts_with_gnu_offset) {
            const name_offset_in_string_table = try fmt.parseInt(u32, mem.trim(u8, trimmed_archive_name[1..trimmed_archive_name.len], " "), 10);

            // Navigate to the start of the string in the string table
            const string_start = string_table_contents[name_offset_in_string_table..string_table_contents.len];

            // Find the end of the string (which is always a newline)
            const end_string_index = mem.indexOf(u8, string_start, "\n");
            if (end_string_index == null) {
                return ParseError.MalformedArchive;
            }
            const string_full = string_start[0..end_string_index.?];

            // String must have a forward slash before the newline, so check that
            // is there and remove it as well!
            if (string_full[string_full.len - 1] != '/') {
                return ParseError.MalformedArchive;
            }

            // Referencing the slice directly is fine as same bumb allocator is
            // used as for the rest of the datastructure!
            trimmed_archive_name = string_full[0 .. string_full.len - 1];
        }

        var seek_forward_amount = try fmt.parseInt(u32, mem.trim(u8, &archive_header.ar_size, " "), 10);

        // Make sure that these allocations get properly disposed of later!
        if (starts_with_bsd_name_length) {
            trimmed_archive_name = trimmed_archive_name[bsd_name_length_signifier.len..trimmed_archive_name.len];
            const archive_name_length = try fmt.parseInt(u32, trimmed_archive_name, 10);

            // TODO: go through int casts & don't assume that they will just work, add defensive error checking
            // for them. (an internal checked cast or similar).

            if (is_first) {
                // TODO: make sure this does a check on self.inferred_archive_type!

                // This could be the symbol table! So parse that here!
                const current_seek_pos = try handleFileIoError(.accessing, self.name, reader.context.getPos());
                var symbol_magic_check_buffer: [bsd_symdef_longest_magic]u8 = undefined;

                // TODO: handle not reading enough characters!
                const chars_read = try reader.read(&symbol_magic_check_buffer);

                var sorted = false;

                const magic_match = magic_match_result: {
                    if (chars_read >= bsd_symdef_magic.len and mem.eql(u8, bsd_symdef_magic, symbol_magic_check_buffer[0..bsd_symdef_magic.len])) {
                        var magic_len = bsd_symdef_magic.len;

                        if (chars_read >= bsd_symdef_64_magic.len and mem.eql(u8, bsd_symdef_64_magic[bsd_symdef_magic.len..], symbol_magic_check_buffer[bsd_symdef_magic.len..])) {
                            magic_len = bsd_symdef_64_magic.len;
                        } else if (chars_read >= bsd_symdef_sorted_magic.len and mem.eql(u8, bsd_symdef_sorted_magic[bsd_symdef_magic.len..], symbol_magic_check_buffer[bsd_symdef_magic.len..])) {
                            magic_len = bsd_symdef_sorted_magic.len;
                            sorted = true;
                        }

                        if (chars_read - magic_len > 0) {
                            try reader.context.seekBy(@intCast(i64, magic_len) - @intCast(i64, chars_read));
                        }

                        seek_forward_amount = seek_forward_amount - @intCast(u32, magic_len);

                        break :magic_match_result true;
                    }

                    break :magic_match_result false;
                };

                if (magic_match) {
                    // TODO: make this target arch endianess
                    const endianess = .Little;

                    {
                        const current_pos = try handleFileIoError(.accessing, self.name, reader.context.getPos());
                        const remainder = @intCast(u32, (self.inferred_archive_type.getAlignment() - current_pos % self.inferred_archive_type.getAlignment()) % self.inferred_archive_type.getAlignment());
                        seek_forward_amount = seek_forward_amount - remainder;
                        try handleFileIoError(.accessing, self.name, reader.context.seekBy(remainder));
                    }

                    // TODO: error if negative (because spec defines this as a long, so should never be that large?)
                    const num_ranlib_bytes = try reader.readInt(IntType, endianess);
                    seek_forward_amount = seek_forward_amount - @as(u32, @sizeOf(IntType));

                    // TODO: error if this doesn't divide properly?
                    // const num_symbols = @divExact(num_ranlib_bytes, @sizeOf(Ranlib(IntType)));

                    var ranlib_bytes = try allocator.alloc(u8, @intCast(u32, num_ranlib_bytes));

                    // TODO: error handling
                    _ = try reader.read(ranlib_bytes);
                    seek_forward_amount = seek_forward_amount - @intCast(u32, num_ranlib_bytes);

                    var ranlibs = mem.bytesAsSlice(Ranlib(IntType), ranlib_bytes);

                    const symbol_strings_length = try reader.readInt(u32, endianess);
                    // TODO: We don't really need this information, but maybe it could come in handy
                    // later?
                    _ = symbol_strings_length;

                    seek_forward_amount = seek_forward_amount - @as(u32, @sizeOf(IntType));

                    const symbol_string_bytes = try allocator.alloc(u8, seek_forward_amount);
                    seek_forward_amount = 0;
                    _ = try reader.read(symbol_string_bytes);

                    for (ranlibs) |ranlib| {
                        const symbol_string = mem.sliceTo(symbol_string_bytes[@intCast(u64, ranlib.ran_strx)..], 0);

                        const symbol = Symbol{
                            .name = symbol_string,
                            // Note - we don't set the final file-index here,
                            // we recalculate and override that later in parsing
                            // when we know what they are!
                            .file_index = @intCast(u64, ranlib.ran_off),
                        };

                        try self.symbols.append(allocator, symbol);
                    }

                    // We have a symbol table!
                    // TODO: parse symbol table, we just skip it for now...
                    try reader.context.seekBy(seek_forward_amount);
                    continue;
                }

                try reader.context.seekTo(current_seek_pos);
            }

            const archive_name_buffer = try allocator.alloc(u8, archive_name_length);

            try handleFileIoError(.reading, self.name, reader.readNoEof(archive_name_buffer));

            seek_forward_amount = seek_forward_amount - archive_name_length;

            // strip null characters from name - TODO find documentation on this
            // could not find documentation on this being needed, but some archivers
            // seems to insert these (for alignment reasons?)
            trimmed_archive_name = mem.trim(u8, archive_name_buffer, "\x00");
        } else {
            const archive_name_buffer = try allocator.alloc(u8, trimmed_archive_name.len);
            mem.copy(u8, archive_name_buffer, trimmed_archive_name);
            trimmed_archive_name = archive_name_buffer;
        }

        const parsed_file = ArchivedFile{
            .name = trimmed_archive_name,
            .contents = Contents{
                .bytes = try allocator.alloc(u8, seek_forward_amount),
                .length = seek_forward_amount,
                .mode = try fmt.parseInt(u32, mem.trim(u8, &archive_header.ar_size, " "), 10),
                .timestamp = timestamp,
                .uid = uid,
                .gid = gid,
            },
        };

        if (self.inferred_archive_type == .gnuthin) {
            var thin_file = try handleFileIoError(.opening, trimmed_archive_name, self.dir.openFile(trimmed_archive_name, .{}));
            defer thin_file.close();

            try handleFileIoError(.reading, trimmed_archive_name, thin_file.reader().readNoEof(parsed_file.contents.bytes));
        } else {
            try handleFileIoError(.reading, self.name, reader.readNoEof(parsed_file.contents.bytes));
        }

        try self.file_name_to_index.put(allocator, trimmed_archive_name, self.files.items.len);
        try file_offset_to_index.put(allocator, file_offset, self.files.items.len);
        try self.files.append(allocator, parsed_file);

        is_first = false;
    }

    if (is_first) {
        const current_position = try handleFileIoError(.accessing, self.name, reader.context.getPos());
        if (current_position > magic_string.len) {
            return ParseError.MalformedArchive;
        }
    }

    for (self.symbols.items) |*symbol| {
        if (file_offset_to_index.get(symbol.file_index)) |file_index| {
            symbol.file_index = file_index;
        } else {
            symbol.file_index = invalid_file_index;
        }
    }

    // Set output archive type based on inference or current os if necessary
    if (self.output_archive_type == .ambiguous) {
        // Set output archive type of one we might just have parsed...
        self.output_archive_type = self.inferred_archive_type;
    }
}

pub const MRIParser = struct {
    script: []const u8,
    archive: ?Archive,
    file_name: ?[]const u8,

    const CommandType = enum {
        open,
        create,
        createthin,
        addmod,
        list,
        delete,
        extract,
        save,
        clear,
        end,
    };

    const Self = @This();

    pub fn init(allocator: Allocator, file: fs.File) !Self {
        const self = Self{
            .script = try file.readToEndAlloc(allocator, std.math.maxInt(usize)),
            .archive = null,
            .file_name = null,
        };

        return self;
    }

    // Returns the next token
    fn getToken(iter: *mem.SplitIterator(u8)) ?[]const u8 {
        while (iter.next()) |tok| {
            if (mem.startsWith(u8, tok, "*")) break;
            if (mem.startsWith(u8, tok, ";")) break;
            return tok;
        }
        return null;
    }

    // Returns a slice of tokens
    fn getTokenLine(allocator: Allocator, iter: *mem.SplitIterator(u8)) ![][]const u8 {
        var list = std.ArrayList([]const u8).init(allocator);
        while (getToken(iter)) |tok| {
            try list.append(tok);
        }
        return list.toOwnedSlice();
    }

    pub fn execute(self: *Self, allocator: Allocator, stdout: fs.File.Writer, stderr: fs.File.Writer) !void {
        // Split the file into lines
        var parser = mem.split(u8, self.script, "\n");

        while (parser.next()) |line| {
            // Split the line by spaces
            var line_parser = mem.split(u8, line, " ");

            if (getToken(&line_parser)) |tok| {
                var command_name = try allocator.dupe(u8, tok);
                defer allocator.free(command_name);

                _ = std.ascii.lowerString(command_name, tok);

                if (std.meta.stringToEnum(CommandType, command_name)) |command| {
                    if (self.archive) |archive| {
                        switch (command) {
                            .addmod => {
                                const file_names = try getTokenLine(allocator, &line_parser);
                                defer allocator.free(file_names);

                                try self.archive.?.insertFiles(allocator, file_names);
                            },
                            .list => {
                                // TODO: verbose output
                                for (archive.files.items) |parsed_file| {
                                    try stdout.print("{s}\n", .{parsed_file.name});
                                }
                            },
                            .delete => {
                                const file_names = try getTokenLine(allocator, &line_parser);
                                try self.archive.?.deleteFiles(file_names);
                            },
                            .extract => {
                                const file_names = try getTokenLine(allocator, &line_parser);
                                try self.archive.?.extract(file_names);
                            },
                            .save => {
                                try self.archive.?.finalize(allocator);
                            },
                            .clear => {
                                // This is a bit of a hack but its reliable.
                                // Instead of clearing out unsaved changes, we re-open the current file, which overwrites the changes.
                                const file = try self.dir.openFile(self.file_name.?, .{ .mode = .read_write });
                                self.archive = Archive.create(file, self.file_name.?);

                                try self.archive.?.parse(allocator, stderr);
                            },
                            .end => return,
                            else => {
                                try stderr.print(
                                    "Archive `{s}` is currently open.\nThe command `{s}` can only be executed when no current archive is active.\n",
                                    .{ self.file_name.?, command_name },
                                );
                                return error.ArchiveAlreadyOpen;
                            },
                        }
                    } else {
                        switch (command) {
                            .open => {
                                const file_name = getToken(&line_parser).?;

                                const file = try self.dir.openFile(file_name, .{ .mode = .read_write });
                                self.archive = Archive.create(file, file_name);
                                self.file_name = file_name;

                                try self.archive.?.parse(allocator, stderr);
                            },
                            .create, .createthin => {
                                // TODO: Thin archives creation
                                const file_name = getToken(&line_parser).?;

                                const file = try self.dir.createFile(file_name, .{ .read = true });
                                self.archive = Archive.create(file, file_name);
                                self.file_name = file_name;

                                try self.archive.?.parse(allocator, stderr);
                            },
                            .end => return,
                            else => {
                                try stderr.print("No currently active archive found.\nThe command `{s}` can only be executed when there is an opened archive.\n", .{command_name});
                                return error.NoCurrentArchive;
                            },
                        }
                    }
                }
            }
        }
    }
};
