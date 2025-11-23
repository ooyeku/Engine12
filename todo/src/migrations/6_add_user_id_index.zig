const Migration = @import("engine12").orm.Migration;

pub const migration = Migration.init(6, "add_user_id_index", "CREATE INDEX IF NOT EXISTS idx_todo_user_id ON todos(user_id)", "DROP INDEX IF EXISTS idx_todo_user_id");
