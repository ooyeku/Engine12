
const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const sqlite3 = c.sqlite3;
pub const sqlite3_stmt = c.sqlite3_stmt;

pub const SQLITE_OK = c.SQLITE_OK;
pub const SQLITE_ERROR = c.SQLITE_ERROR;
pub const SQLITE_BUSY = c.SQLITE_BUSY;
pub const SQLITE_LOCKED = c.SQLITE_LOCKED;
pub const SQLITE_NOMEM = c.SQLITE_NOMEM;
pub const SQLITE_READONLY = c.SQLITE_READONLY;
pub const SQLITE_INTERRUPT = c.SQLITE_INTERRUPT;
pub const SQLITE_IOERR = c.SQLITE_IOERR;
pub const SQLITE_CORRUPT = c.SQLITE_CORRUPT;
pub const SQLITE_NOTFOUND = c.SQLITE_NOTFOUND;
pub const SQLITE_FULL = c.SQLITE_FULL;
pub const SQLITE_CANTOPEN = c.SQLITE_CANTOPEN;
pub const SQLITE_PROTOCOL = c.SQLITE_PROTOCOL;
pub const SQLITE_EMPTY = c.SQLITE_EMPTY;
pub const SQLITE_SCHEMA = c.SQLITE_SCHEMA;
pub const SQLITE_TOOBIG = c.SQLITE_TOOBIG;
pub const SQLITE_CONSTRAINT = c.SQLITE_CONSTRAINT;
pub const SQLITE_MISMATCH = c.SQLITE_MISMATCH;
pub const SQLITE_MISUSE = c.SQLITE_MISUSE;
pub const SQLITE_NOLFS = c.SQLITE_NOLFS;
pub const SQLITE_AUTH = c.SQLITE_AUTH;
pub const SQLITE_FORMAT = c.SQLITE_FORMAT;
pub const SQLITE_RANGE = c.SQLITE_RANGE;
pub const SQLITE_NOTADB = c.SQLITE_NOTADB;
pub const SQLITE_ROW = c.SQLITE_ROW;
pub const SQLITE_DONE = c.SQLITE_DONE;

pub const SQLITE_INTEGER = c.SQLITE_INTEGER;
pub const SQLITE_FLOAT = c.SQLITE_FLOAT;
pub const SQLITE_TEXT = c.SQLITE_TEXT;
pub const SQLITE_BLOB = c.SQLITE_BLOB;
pub const SQLITE_NULL = c.SQLITE_NULL;

pub const SQLITE_STATIC: c.sqlite3_destructor_type = null;

pub const SQLITE_OPEN_READONLY = c.SQLITE_OPEN_READONLY;
pub const SQLITE_OPEN_READWRITE = c.SQLITE_OPEN_READWRITE;
pub const SQLITE_OPEN_CREATE = c.SQLITE_OPEN_CREATE;
pub const SQLITE_OPEN_NOMUTEX = c.SQLITE_OPEN_NOMUTEX;
pub const SQLITE_OPEN_FULLMUTEX = c.SQLITE_OPEN_FULLMUTEX;
pub const SQLITE_OPEN_SHAREDCACHE = c.SQLITE_OPEN_SHAREDCACHE;
pub const SQLITE_OPEN_PRIVATECACHE = c.SQLITE_OPEN_PRIVATECACHE;

pub const open = c.sqlite3_open;
pub const open_v2 = c.sqlite3_open_v2;
pub const close = c.sqlite3_close;
pub const errmsg = c.sqlite3_errmsg;
pub const changes = c.sqlite3_changes;
pub const last_insert_rowid = c.sqlite3_last_insert_rowid;

pub const exec = c.sqlite3_exec;

pub const prepare_v2 = c.sqlite3_prepare_v2;
pub const step = c.sqlite3_step;
pub const reset = c.sqlite3_reset;
pub const finalize = c.sqlite3_finalize;
pub const clear_bindings = c.sqlite3_clear_bindings;

pub const column_count = c.sqlite3_column_count;
pub const column_name = c.sqlite3_column_name;
pub const column_type = c.sqlite3_column_type;

pub const column_text = c.sqlite3_column_text;
pub const column_int64 = c.sqlite3_column_int64;
pub const column_double = c.sqlite3_column_double;
pub const column_blob = c.sqlite3_column_blob;
pub const column_bytes = c.sqlite3_column_bytes;

pub const bind_null = c.sqlite3_bind_null;
pub const bind_int64 = c.sqlite3_bind_int64;
pub const bind_double = c.sqlite3_bind_double;
pub const bind_text = c.sqlite3_bind_text;
pub const bind_blob = c.sqlite3_bind_blob;

pub fn getErrorMessage(db: ?*sqlite3) []const u8 {
    const msg = errmsg(db);
    if (msg == null) return "Unknown error";
    return std.mem.sliceTo(msg, 0);
}

pub fn getColumnName(stmt: ?*sqlite3_stmt, col: c_int) ?[]const u8 {
    const name = column_name(stmt, col);
    if (name == null) return null;
    return std.mem.sliceTo(name, 0);
}

pub fn getColumnText(stmt: ?*sqlite3_stmt, col: c_int) ?[]const u8 {
    const text = column_text(stmt, col);
    if (text == null) return null;
    return std.mem.sliceTo(text, 0);
}

pub fn isColumnNull(stmt: ?*sqlite3_stmt, col: c_int) bool {
    return column_type(stmt, col) == SQLITE_NULL;
}
