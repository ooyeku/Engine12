#ifndef E12_ORM_H
#define E12_ORM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handles - these are pointer types, never dereference them
typedef void E12Database;
typedef void E12Result;
typedef void E12Row;
typedef void E12Transaction;
typedef void E12ConnectionPool;
typedef void E12StmtCache;
typedef void E12PreparedStmt;

// Parameter types for bound parameters
typedef enum {
    E12_PARAM_NULL = 0,
    E12_PARAM_INT64 = 1,
    E12_PARAM_DOUBLE = 2,
    E12_PARAM_TEXT = 3,
    E12_PARAM_BLOB = 4,
} E12ParamType;

// Parameter value union
typedef struct {
    E12ParamType type;
    union {
        int64_t i64;
        double f64;
        struct {
            const char* ptr;
            size_t len;
        } text;
        struct {
            const void* ptr;
            size_t len;
        } blob;
    } value;
} E12Param;

// Error codes
typedef enum {
    E12_ORM_OK = 0,
    E12_ORM_ERROR = 1,
    E12_ORM_ERROR_OPEN_FAILED = 2,
    E12_ORM_ERROR_QUERY_FAILED = 3,
    E12_ORM_ERROR_INVALID_ARGUMENT = 4,
    E12_ORM_ERROR_NO_RESULTS = 5,
} E12ORMErrorCode;

// ============================================================================
// Database Operations
// ============================================================================

/// Open a SQLite database
/// @param path Database file path (will be created if doesn't exist)
/// @param out_db Output parameter for the database handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_open(const char* path, E12Database** out_db);

/// Close a database connection
/// @param db Database handle (must not be NULL)
void e12_db_close(E12Database* db);

/// Execute a SQL statement (INSERT, UPDATE, DELETE, CREATE TABLE, etc.)
/// @param db Database handle
/// @param sql SQL statement string
/// @param rows_affected Output parameter for number of rows affected (can be NULL)
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_execute(E12Database* db, const char* sql, int64_t* rows_affected);

// ============================================================================
// Query Operations
// ============================================================================

/// Execute a SELECT query and return a result set
/// @param db Database handle
/// @param sql SQL SELECT statement
/// @param out_result Output parameter for the result handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_query(E12Database* db, const char* sql, E12Result** out_result);

/// Get the number of columns in a result set
/// @param result Result handle
/// @return Number of columns, or 0 if invalid
int e12_result_column_count(E12Result* result);

/// Get the name of a column by index
/// @param result Result handle
/// @param col_index Column index (0-based)
/// @return Column name (owned by result, do not free), NULL if invalid
const char* e12_result_column_name(E12Result* result, int col_index);

/// Get the next row from the result set
/// @param result Result handle
/// @param out_row Output parameter for the row handle (NULL if no more rows)
/// @return true if a row was returned, false if no more rows
bool e12_result_next_row(E12Result* result, E12Row** out_row);

/// Free a result set
/// @param result Result handle to free
void e12_result_free(E12Result* result);

// ============================================================================
// Parameterized Query Operations
// ============================================================================

/// Prepare a SQL statement for parameter binding
/// @param db Database handle
/// @param sql SQL statement with ? placeholders
/// @param out_stmt Output parameter for the prepared statement handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_prepare(E12Database* db, const char* sql, E12PreparedStmt** out_stmt);

/// Bind an integer parameter to a prepared statement
/// @param stmt Prepared statement handle
/// @param index Parameter index (1-based)
/// @param value Integer value to bind
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_bind_int64(E12PreparedStmt* stmt, int index, int64_t value);

/// Bind a double parameter to a prepared statement
/// @param stmt Prepared statement handle
/// @param index Parameter index (1-based)
/// @param value Double value to bind
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_bind_double(E12PreparedStmt* stmt, int index, double value);

/// Bind a text parameter to a prepared statement
/// @param stmt Prepared statement handle
/// @param index Parameter index (1-based)
/// @param value Text value to bind (null-terminated)
/// @param len Length of text (-1 for strlen)
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_bind_text(E12PreparedStmt* stmt, int index, const char* value, int len);

/// Bind a NULL parameter to a prepared statement
/// @param stmt Prepared statement handle
/// @param index Parameter index (1-based)
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_bind_null(E12PreparedStmt* stmt, int index);

/// Execute a prepared statement (for INSERT, UPDATE, DELETE)
/// @param stmt Prepared statement handle
/// @param rows_affected Output parameter for number of rows affected (can be NULL)
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_execute(E12PreparedStmt* stmt, int64_t* rows_affected);

/// Execute a prepared statement and return result set (for SELECT)
/// @param stmt Prepared statement handle
/// @param out_result Output parameter for the result handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_query(E12PreparedStmt* stmt, E12Result** out_result);

/// Reset a prepared statement for reuse with new parameters
/// @param stmt Prepared statement handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_reset(E12PreparedStmt* stmt);

/// Free a prepared statement
/// @param stmt Prepared statement handle to free
void e12_stmt_free(E12PreparedStmt* stmt);

/// Execute a parameterized query with an array of parameters
/// @param db Database handle
/// @param sql SQL statement with ? placeholders
/// @param params Array of parameters
/// @param param_count Number of parameters
/// @param rows_affected Output parameter for number of rows affected (can be NULL)
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_execute_params(E12Database* db, const char* sql, 
                                       const E12Param* params, size_t param_count,
                                       int64_t* rows_affected);

/// Execute a parameterized SELECT query with an array of parameters
/// @param db Database handle
/// @param sql SQL statement with ? placeholders
/// @param params Array of parameters
/// @param param_count Number of parameters
/// @param out_result Output parameter for the result handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_query_params(E12Database* db, const char* sql,
                                     const E12Param* params, size_t param_count,
                                     E12Result** out_result);

// ============================================================================
// Row Operations
// ============================================================================

/// Get a text value from a row by column index
/// @param row Row handle
/// @param col_index Column index (0-based)
/// @return Text value (owned by result, do not free), NULL if invalid or NULL in database
const char* e12_row_get_text(E12Row* row, int col_index);

/// Get an integer value from a row by column index
/// @param row Row handle
/// @param col_index Column index (0-based)
/// @return Integer value, or 0 if invalid or NULL in database
int64_t e12_row_get_int64(E12Row* row, int col_index);

/// Get a double value from a row by column index
/// @param row Row handle
/// @param col_index Column index (0-based)
/// @return Double value, or 0.0 if invalid or NULL in database
double e12_row_get_double(E12Row* row, int col_index);

/// Check if a column value is NULL
/// @param row Row handle
/// @param col_index Column index (0-based)
/// @return true if NULL, false otherwise
bool e12_row_is_null(E12Row* row, int col_index);

/// Free a row handle
/// @param row Row handle to free
void e12_row_free(E12Row* row);

// ============================================================================
// Transaction Operations
// ============================================================================

/// Begin a database transaction
/// @param db Database handle
/// @param out_transaction Output parameter for the transaction handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_begin_transaction(E12Database* db, E12Transaction** out_transaction);

/// Commit a transaction
/// @param transaction Transaction handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_commit(E12Transaction* transaction);

/// Rollback a transaction
/// @param transaction Transaction handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_rollback(E12Transaction* transaction);

/// Free a transaction handle
/// @param transaction Transaction handle to free
void e12_transaction_free(E12Transaction* transaction);

// ============================================================================
// Connection Pool Operations
// ============================================================================

/// Connection pool configuration
typedef struct {
    size_t max_connections;
    uint64_t idle_timeout_ms;
    uint64_t acquire_timeout_ms;
} E12ConnectionPoolConfig;

/// Create a connection pool
/// @param path Database file path
/// @param config Pool configuration
/// @param out_pool Output parameter for the pool handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_pool_create(const char* path, const E12ConnectionPoolConfig* config, E12ConnectionPool** out_pool);

/// Acquire a connection from the pool
/// @param pool Pool handle
/// @param out_db Output parameter for the database handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_pool_acquire(E12ConnectionPool* pool, E12Database** out_db);

/// Return a connection to the pool
/// @param pool Pool handle
/// @param db Database handle to return
void e12_pool_release(E12ConnectionPool* pool, E12Database* db);

/// Close a connection pool
/// @param pool Pool handle to close
void e12_pool_close(E12ConnectionPool* pool);

// ============================================================================
// Prepared Statement Cache Operations
// ============================================================================

/// Create a prepared statement cache for a database
/// The cache stores compiled SQL statements for reuse, improving performance
/// @param db Database handle
/// @param max_statements Maximum number of statements to cache (0 = default 512)
/// @param out_cache Output parameter for the cache handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_cache_create(E12Database* db, size_t max_statements, E12StmtCache** out_cache);

/// Get or prepare a statement from the cache
/// If the SQL is cached, returns the cached statement (reset for reuse)
/// If not cached, prepares a new statement and caches it
/// @param cache Cache handle
/// @param sql SQL statement string
/// @param out_result Output parameter for the result handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_stmt_cache_query(E12StmtCache* cache, const char* sql, E12Result** out_result);

/// Clear all cached statements
/// @param cache Cache handle
void e12_stmt_cache_clear(E12StmtCache* cache);

/// Destroy the statement cache and free all resources
/// @param cache Cache handle to destroy
void e12_stmt_cache_destroy(E12StmtCache* cache);

/// Get cache statistics
/// @param cache Cache handle
/// @param out_hits Output parameter for cache hits
/// @param out_misses Output parameter for cache misses
void e12_stmt_cache_stats(E12StmtCache* cache, uint64_t* out_hits, uint64_t* out_misses);

// ============================================================================
// Error Handling
// ============================================================================

/// Get the last error message
/// @return Error message string (owned by ORM, do not free), NULL if no error
const char* e12_orm_get_last_error(void);

/// Get the last error code
/// @return Error code
E12ORMErrorCode e12_orm_get_last_error_code(void);

#ifdef __cplusplus
}
#endif

#endif // E12_ORM_H

