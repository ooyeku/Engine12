//! ORM module
//!
//! This module provides Object-Relational Mapping for Engine12.
//! Supports SQLite and PostgreSQL with migrations, query building, and model management.
//!
//! ## Components
//!
//! - **orm** - Main ORM interface
//! - **database** - Database connection management
//! - **model** - Model definition and operations
//! - **query_builder** - SQL query builder
//! - **migration** - Database migrations
//! - **schema** - Schema introspection
//! - **sqlite** - SQLite driver
//! - **postgres** - PostgreSQL driver
//!
//! ## Example
//! ```zig
//! const orm_mod = @import("orm/module.zig");
//!
//! const User = struct {
//!     id: i64 = 0,
//!     name: []const u8,
//!     email: []const u8,
//! };
//!
//! var db = try orm_mod.database.Database.init(allocator, .sqlite, "data.db");
//! defer db.deinit();
//!
//! var user_model = try orm_mod.orm.Model(User).init(allocator, &db, "users");
//! defer user_model.deinit();
//!
//! // Find all users
//! const users = try user_model.findAll();
//! defer user_model.freeResults(users);
//! ```

pub const orm = @import("orm.zig");
pub const database = @import("database.zig");
pub const driver = @import("driver.zig");
pub const model = @import("model.zig");
pub const model_wrapper = @import("model_wrapper.zig");
pub const query_builder = @import("query_builder.zig");
pub const migration = @import("migration.zig");
pub const migration_discovery = @import("migration_discovery.zig");
pub const migration_runner = @import("migration_runner.zig");
pub const schema = @import("schema.zig");
pub const sqlite = @import("sqlite.zig");
pub const postgres = @import("postgres.zig");
pub const row = @import("row.zig");
pub const params = @import("params.zig");
pub const owned = @import("owned.zig");
pub const singleton = @import("singleton.zig");
pub const sql_escape = @import("sql_escape.zig");
pub const sql_splitter = @import("sql_splitter.zig");

// Re-export commonly used types
pub const Database = database.Database;
pub const Model = orm.Model;
pub const QueryBuilder = query_builder.QueryBuilder;
pub const Migration = migration.Migration;
