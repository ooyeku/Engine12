const Migration = @import("engine12").orm.Migration;

pub const migration = Migration.init(5, "add_user_id",
    \\ALTER TABLE todos ADD COLUMN user_id INTEGER DEFAULT 1;
    \\-- Ensure all existing rows have user_id set (DEFAULT only applies to new rows)
    \\UPDATE todos SET user_id = 1 WHERE user_id IS NULL;
, "-- Cannot automatically reverse ALTER TABLE ADD COLUMN");
