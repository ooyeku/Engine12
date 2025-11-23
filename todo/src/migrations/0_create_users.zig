const Migration = @import("engine12").orm.Migration;

pub const migration = Migration.init(0, "create_users",
    \\CREATE TABLE IF NOT EXISTS users (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  username TEXT NOT NULL UNIQUE,
    \\  email TEXT NOT NULL UNIQUE,
    \\  password_hash TEXT NOT NULL,
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
    \\CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
, "DROP TABLE IF EXISTS users");
