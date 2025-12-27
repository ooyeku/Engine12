const std = @import("std");

/// Postgres Protocol Message Types (Frontend)
pub const Frontend = enum(u8) {
    Bind = 'B',
    Close = 'C',
    Describe = 'D',
    Execute = 'E',
    Flush = 'H',
    Parse = 'P',
    Query = 'Q',
    Sync = 'S',
    Terminate = 'X',
    PasswordMessage = 'p',
};

/// Postgres Protocol Message Types (Backend)
pub const Backend = enum(u8) {
    Authentication = 'R',
    BackendKeyData = 'K',
    BindComplete = '2',
    CloseComplete = '3',
    CommandComplete = 'C',
    DataRow = 'D',
    EmptyQueryResponse = 'I',
    ErrorResponse = 'E',
    NoData = 'n',
    NoticeResponse = 'N',
    NotificationResponse = 'A',
    ParameterDescription = 't',
    ParameterStatus = 'S',
    ParseComplete = '1',
    PortalSuspended = 's',
    ReadyForQuery = 'Z',
    RowDescription = 'T',
    _,
};

/// Common OIDs (Object Identifiers) for Types
pub const OID = enum(i32) {
    Bool = 16,
    Bytea = 17,
    Int8 = 20,
    Int2 = 21,
    Int4 = 23,
    Text = 25,
    Json = 114,
    Float4 = 700,
    Float8 = 701,
    Varchar = 1043,
    Date = 1082,
    Time = 1083,
    Timestamp = 1114,
    TimestampTz = 1184,
    Uuid = 2950,
    Jsonb = 3802,
    _,

    pub fn isInteger(self: OID) bool {
        return switch (self) {
            .Int2, .Int4, .Int8 => true,
            else => false,
        };
    }

    pub fn isFloat(self: OID) bool {
        return switch (self) {
            .Float4, .Float8 => true,
            else => false,
        };
    }

    pub fn isText(self: OID) bool {
        return switch (self) {
            .Text, .Varchar, .Json, .Jsonb, .Uuid => true,
            else => false,
        };
    }
};

/// Transaction Status from ReadyForQuery
pub const TransactionStatus = enum(u8) {
    Idle = 'I',
    InTransaction = 'T',
    Error = 'E',
};

/// Error Severity from ErrorResponse
pub const Severity = enum {
    Log,
    Info,
    Debug,
    Notice,
    Warning,
    Error,
    Fatal,
    Panic,
    Unknown,

    pub fn fromString(s: []const u8) Severity {
        if (std.mem.eql(u8, s, "LOG")) return .Log;
        if (std.mem.eql(u8, s, "INFO")) return .Info;
        if (std.mem.eql(u8, s, "DEBUG")) return .Debug;
        if (std.mem.eql(u8, s, "NOTICE")) return .Notice;
        if (std.mem.eql(u8, s, "WARNING")) return .Warning;
        if (std.mem.eql(u8, s, "ERROR")) return .Error;
        if (std.mem.eql(u8, s, "FATAL")) return .Fatal;
        if (std.mem.eql(u8, s, "PANIC")) return .Panic;
        return .Unknown;
    }
};

/// Protocol Errors
pub const ProtocolError = error{
    ConnectionRefused,
    HostNotFound,
    SocketError,
    ConnectionClosed,
    AuthenticationFailed,
    ProtocolViolation,
    UnsupportedAuthentication,
    MessageTooLong,
    UnexpectedMessage,
    // Database specific errors
    QueryError,
    DuplicateKey,
    ForeignKeyViolation,
    NotNullViolation,
    CheckViolation,
    SerializationFailure,
    DeadlockDetected,
    UnknownDatabaseError,
};

/// Authentication Request Types
pub const AuthType = enum(i32) {
    Ok = 0,
    KerberosV5 = 2,
    CleartextPassword = 3,
    Md5Password = 5,
    ScmCredential = 6,
    Gss = 7,
    Sspi = 9,
    GssContinue = 8,
    Sasl = 10,
    SaslContinue = 11,
    SaslFinal = 12,
    _,
};
