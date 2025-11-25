#include "e12_orm.h"
#include "sqlite3.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Error state
static E12ORMErrorCode last_error_code = E12_ORM_OK;
static char last_error_msg[512] = {0};

static void set_error(E12ORMErrorCode code, const char* msg) {
    last_error_code = code;
    if (msg) {
        strncpy(last_error_msg, msg, sizeof(last_error_msg) - 1);
        last_error_msg[sizeof(last_error_msg) - 1] = '\0';
    } else {
        last_error_msg[0] = '\0';
    }
}

static void clear_error(void) {
    last_error_code = E12_ORM_OK;
    last_error_msg[0] = '\0';
}

// Database structure
typedef struct {
    sqlite3* db;
} E12DatabaseImpl;

// Result structure
typedef struct {
    sqlite3_stmt* stmt;
    int column_count;
    bool has_row;
    bool row_fetched;
    bool owns_stmt;     // If true, finalize stmt on free; if false, stmt is cached
} E12ResultImpl;

// Row structure (just a pointer to the result)
typedef struct {
    E12ResultImpl* result;
} E12RowImpl;

// Transaction structure
typedef struct {
    E12DatabaseImpl* db;
    bool committed;
    bool rolled_back;
} E12TransactionImpl;

// Prepared statement cache entry
typedef struct E12StmtCacheEntry {
    char* sql;                      // SQL string (owned)
    sqlite3_stmt* stmt;             // Prepared statement
    struct E12StmtCacheEntry* next; // Next entry in bucket
} E12StmtCacheEntry;

// Prepared statement cache structure
typedef struct {
    E12DatabaseImpl* db;            // Database handle
    E12StmtCacheEntry** buckets;    // Hash table buckets
    size_t bucket_count;            // Number of buckets
    size_t entry_count;             // Number of cached statements
    size_t max_statements;          // Maximum statements to cache
    uint64_t hits;                  // Cache hits
    uint64_t misses;                // Cache misses
} E12StmtCacheImpl;

// Simple hash function for SQL strings
static size_t hash_sql(const char* sql, size_t bucket_count) {
    size_t hash = 5381;
    int c;
    while ((c = *sql++)) {
        hash = ((hash << 5) + hash) + c; // hash * 33 + c
    }
    return hash % bucket_count;
}

// ============================================================================
// Database Operations
// ============================================================================

E12ORMErrorCode e12_db_open(const char* path, E12Database** out_db) {
    clear_error();
    
    if (!path || !out_db) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)malloc(sizeof(E12DatabaseImpl));
    if (!db_impl) {
        set_error(E12_ORM_ERROR, "Memory allocation failed");
        return E12_ORM_ERROR;
    }
    
    int rc = sqlite3_open(path, &db_impl->db);
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_OPEN_FAILED, sqlite3_errmsg(db_impl->db));
        sqlite3_close(db_impl->db);
        free(db_impl);
        return E12_ORM_ERROR_OPEN_FAILED;
    }
    
    *out_db = (E12Database*)db_impl;
    return E12_ORM_OK;
}

void e12_db_close(E12Database* db) {
    if (!db) return;
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)db;
    if (db_impl->db) {
        sqlite3_close(db_impl->db);
    }
    free(db_impl);
}

E12ORMErrorCode e12_db_execute(E12Database* db, const char* sql, int64_t* rows_affected) {
    clear_error();
    
    if (!db || !sql) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)db;
    
    char* err_msg = NULL;
    int rc = sqlite3_exec(db_impl->db, sql, NULL, NULL, &err_msg);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, err_msg ? err_msg : "Query failed");
        if (err_msg) {
            sqlite3_free(err_msg);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    if (rows_affected) {
        *rows_affected = sqlite3_changes(db_impl->db);
    }
    
    return E12_ORM_OK;
}

// ============================================================================
// Query Operations
// ============================================================================

E12ORMErrorCode e12_db_query(E12Database* db, const char* sql, E12Result** out_result) {
    clear_error();
    
    if (!db || !sql || !out_result) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)db;
    
    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2(db_impl->db, sql, -1, &stmt, NULL);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, sqlite3_errmsg(db_impl->db));
        if (stmt) {
            sqlite3_finalize(stmt);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    E12ResultImpl* result_impl = (E12ResultImpl*)malloc(sizeof(E12ResultImpl));
    if (!result_impl) {
        set_error(E12_ORM_ERROR, "Memory allocation failed");
        sqlite3_finalize(stmt);
        return E12_ORM_ERROR;
    }
    
    result_impl->stmt = stmt;
    result_impl->column_count = sqlite3_column_count(stmt);
    result_impl->has_row = false;
    result_impl->row_fetched = false;
    result_impl->owns_stmt = true;  // Regular query owns its statement
    
    *out_result = (E12Result*)result_impl;
    return E12_ORM_OK;
}

int e12_result_column_count(E12Result* result) {
    if (!result) return 0;
    E12ResultImpl* result_impl = (E12ResultImpl*)result;
    return result_impl->column_count;
}

const char* e12_result_column_name(E12Result* result, int col_index) {
    if (!result) return NULL;
    E12ResultImpl* result_impl = (E12ResultImpl*)result;
    if (col_index < 0 || col_index >= result_impl->column_count) {
        return NULL;
    }
    return sqlite3_column_name(result_impl->stmt, col_index);
}

bool e12_result_next_row(E12Result* result, E12Row** out_row) {
    if (!result || !out_row) return false;
    
    E12ResultImpl* result_impl = (E12ResultImpl*)result;
    
    // If we already fetched a row, step to the next one
    if (result_impl->row_fetched) {
        int rc = sqlite3_step(result_impl->stmt);
        if (rc == SQLITE_ROW) {
            result_impl->has_row = true;
        } else {
            result_impl->has_row = false;
            *out_row = NULL;
            return false;
        }
    } else {
        // First row
        int rc = sqlite3_step(result_impl->stmt);
        result_impl->row_fetched = true;
        if (rc == SQLITE_ROW) {
            result_impl->has_row = true;
        } else {
            result_impl->has_row = false;
            *out_row = NULL;
            return false;
        }
    }
    
    // Create row handle
    E12RowImpl* row_impl = (E12RowImpl*)malloc(sizeof(E12RowImpl));
    if (!row_impl) {
        result_impl->has_row = false;
        *out_row = NULL;
        return false;
    }
    
    row_impl->result = result_impl;
    *out_row = (E12Row*)row_impl;
    return true;
}

void e12_result_free(E12Result* result) {
    if (!result) return;
    
    E12ResultImpl* result_impl = (E12ResultImpl*)result;
    // Only finalize if we own the statement (not from cache)
    if (result_impl->stmt && result_impl->owns_stmt) {
        sqlite3_finalize(result_impl->stmt);
    }
    free(result_impl);
}

// ============================================================================
// Row Operations
// ============================================================================

const char* e12_row_get_text(E12Row* row, int col_index) {
    if (!row) return NULL;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    E12ResultImpl* result_impl = row_impl->result;
    
    if (!result_impl || !result_impl->has_row) return NULL;
    if (col_index < 0 || col_index >= result_impl->column_count) return NULL;
    
    const unsigned char* text = sqlite3_column_text(result_impl->stmt, col_index);
    return (const char*)text;
}

int64_t e12_row_get_int64(E12Row* row, int col_index) {
    if (!row) return 0;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    E12ResultImpl* result_impl = row_impl->result;
    
    if (!result_impl || !result_impl->has_row) return 0;
    if (col_index < 0 || col_index >= result_impl->column_count) return 0;
    
    return sqlite3_column_int64(result_impl->stmt, col_index);
}

double e12_row_get_double(E12Row* row, int col_index) {
    if (!row) return 0.0;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    E12ResultImpl* result_impl = row_impl->result;
    
    if (!result_impl || !result_impl->has_row) return 0.0;
    if (col_index < 0 || col_index >= result_impl->column_count) return 0.0;
    
    return sqlite3_column_double(result_impl->stmt, col_index);
}

bool e12_row_is_null(E12Row* row, int col_index) {
    if (!row) return true;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    E12ResultImpl* result_impl = row_impl->result;
    
    if (!result_impl || !result_impl->has_row) return true;
    if (col_index < 0 || col_index >= result_impl->column_count) return true;
    
    return sqlite3_column_type(result_impl->stmt, col_index) == SQLITE_NULL;
}

void e12_row_free(E12Row* row) {
    if (!row) return;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    free(row_impl);
}

// ============================================================================
// Transaction Operations
// ============================================================================

E12ORMErrorCode e12_db_begin_transaction(E12Database* db, E12Transaction** out_transaction) {
    clear_error();
    
    if (!db || !out_transaction) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)db;
    
    // Begin transaction
    char* err_msg = NULL;
    int rc = sqlite3_exec(db_impl->db, "BEGIN TRANSACTION", NULL, NULL, &err_msg);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, err_msg ? err_msg : "Failed to begin transaction");
        if (err_msg) {
            sqlite3_free(err_msg);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    // Create transaction handle
    E12TransactionImpl* trans_impl = (E12TransactionImpl*)malloc(sizeof(E12TransactionImpl));
    if (!trans_impl) {
        sqlite3_exec(db_impl->db, "ROLLBACK", NULL, NULL, NULL);
        set_error(E12_ORM_ERROR, "Memory allocation failed");
        return E12_ORM_ERROR;
    }
    
    trans_impl->db = db_impl;
    trans_impl->committed = false;
    trans_impl->rolled_back = false;
    
    *out_transaction = (E12Transaction*)trans_impl;
    return E12_ORM_OK;
}

E12ORMErrorCode e12_db_commit(E12Transaction* transaction) {
    clear_error();
    
    if (!transaction) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid transaction");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12TransactionImpl* trans_impl = (E12TransactionImpl*)transaction;
    
    if (trans_impl->committed || trans_impl->rolled_back) {
        set_error(E12_ORM_ERROR, "Transaction already completed");
        return E12_ORM_ERROR;
    }
    
    char* err_msg = NULL;
    int rc = sqlite3_exec(trans_impl->db->db, "COMMIT", NULL, NULL, &err_msg);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, err_msg ? err_msg : "Failed to commit transaction");
        if (err_msg) {
            sqlite3_free(err_msg);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    trans_impl->committed = true;
    return E12_ORM_OK;
}

E12ORMErrorCode e12_db_rollback(E12Transaction* transaction) {
    clear_error();
    
    if (!transaction) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid transaction");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12TransactionImpl* trans_impl = (E12TransactionImpl*)transaction;
    
    if (trans_impl->committed || trans_impl->rolled_back) {
        set_error(E12_ORM_ERROR, "Transaction already completed");
        return E12_ORM_ERROR;
    }
    
    char* err_msg = NULL;
    int rc = sqlite3_exec(trans_impl->db->db, "ROLLBACK", NULL, NULL, &err_msg);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, err_msg ? err_msg : "Failed to rollback transaction");
        if (err_msg) {
            sqlite3_free(err_msg);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    trans_impl->rolled_back = true;
    return E12_ORM_OK;
}

void e12_transaction_free(E12Transaction* transaction) {
    if (!transaction) return;
    
    E12TransactionImpl* trans_impl = (E12TransactionImpl*)transaction;
    
    // Auto-rollback if not committed or rolled back
    if (!trans_impl->committed && !trans_impl->rolled_back) {
        sqlite3_exec(trans_impl->db->db, "ROLLBACK", NULL, NULL, NULL);
    }
    
    free(trans_impl);
}

// ============================================================================
// Connection Pool Operations
// ============================================================================

// Note: Connection pooling is primarily implemented at the Zig level
// These C functions are stubs for future expansion

E12ORMErrorCode e12_pool_create(const char* path, const E12ConnectionPoolConfig* config, E12ConnectionPool** out_pool) {
    clear_error();
    (void)path;
    (void)config;
    (void)out_pool;
    set_error(E12_ORM_ERROR, "Connection pooling not yet implemented in C API");
    return E12_ORM_ERROR;
}

E12ORMErrorCode e12_pool_acquire(E12ConnectionPool* pool, E12Database** out_db) {
    clear_error();
    (void)pool;
    (void)out_db;
    set_error(E12_ORM_ERROR, "Connection pooling not yet implemented in C API");
    return E12_ORM_ERROR;
}

void e12_pool_release(E12ConnectionPool* pool, E12Database* db) {
    (void)pool;
    (void)db;
}

void e12_pool_close(E12ConnectionPool* pool) {
    (void)pool;
}

// ============================================================================
// Prepared Statement Cache Operations
// ============================================================================

E12ORMErrorCode e12_stmt_cache_create(E12Database* db, size_t max_statements, E12StmtCache** out_cache) {
    clear_error();
    
    if (!db || !out_cache) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12StmtCacheImpl* cache = (E12StmtCacheImpl*)malloc(sizeof(E12StmtCacheImpl));
    if (!cache) {
        set_error(E12_ORM_ERROR, "Memory allocation failed");
        return E12_ORM_ERROR;
    }
    
    // Default to 128 statements if not specified
    if (max_statements == 0) {
        max_statements = 128;
    }
    
    // Use prime number of buckets for better distribution
    size_t bucket_count = max_statements * 2 + 1;
    
    cache->buckets = (E12StmtCacheEntry**)calloc(bucket_count, sizeof(E12StmtCacheEntry*));
    if (!cache->buckets) {
        free(cache);
        set_error(E12_ORM_ERROR, "Memory allocation failed");
        return E12_ORM_ERROR;
    }
    
    cache->db = (E12DatabaseImpl*)db;
    cache->bucket_count = bucket_count;
    cache->entry_count = 0;
    cache->max_statements = max_statements;
    cache->hits = 0;
    cache->misses = 0;
    
    *out_cache = (E12StmtCache*)cache;
    return E12_ORM_OK;
}

E12ORMErrorCode e12_stmt_cache_query(E12StmtCache* cache, const char* sql, E12Result** out_result) {
    clear_error();
    
    if (!cache || !sql || !out_result) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12StmtCacheImpl* cache_impl = (E12StmtCacheImpl*)cache;
    size_t bucket_idx = hash_sql(sql, cache_impl->bucket_count);
    
    // Look for existing cached statement
    E12StmtCacheEntry* entry = cache_impl->buckets[bucket_idx];
    while (entry) {
        if (strcmp(entry->sql, sql) == 0) {
            // Cache hit! Reset and reuse statement
            cache_impl->hits++;
            sqlite3_reset(entry->stmt);
            sqlite3_clear_bindings(entry->stmt);
            
            // Create result wrapper
            E12ResultImpl* result_impl = (E12ResultImpl*)malloc(sizeof(E12ResultImpl));
            if (!result_impl) {
                set_error(E12_ORM_ERROR, "Memory allocation failed");
                return E12_ORM_ERROR;
            }
            
            result_impl->stmt = entry->stmt;
            result_impl->column_count = sqlite3_column_count(entry->stmt);
            result_impl->has_row = false;
            result_impl->row_fetched = false;
            result_impl->owns_stmt = false;  // Cached statement - don't finalize on free
            
            *out_result = (E12Result*)result_impl;
            return E12_ORM_OK;
        }
        entry = entry->next;
    }
    
    // Cache miss - prepare new statement
    cache_impl->misses++;
    
    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2(cache_impl->db->db, sql, -1, &stmt, NULL);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, sqlite3_errmsg(cache_impl->db->db));
        if (stmt) {
            sqlite3_finalize(stmt);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    // Track whether we cached the statement
    bool stmt_cached = false;
    
    // Cache the statement if we have room
    if (cache_impl->entry_count < cache_impl->max_statements) {
        E12StmtCacheEntry* new_entry = (E12StmtCacheEntry*)malloc(sizeof(E12StmtCacheEntry));
        if (new_entry) {
            new_entry->sql = strdup(sql);
            if (new_entry->sql) {
                new_entry->stmt = stmt;
                new_entry->next = cache_impl->buckets[bucket_idx];
                cache_impl->buckets[bucket_idx] = new_entry;
                cache_impl->entry_count++;
                stmt_cached = true;
            } else {
                free(new_entry);
            }
        }
    }
    
    // Create result wrapper
    E12ResultImpl* result_impl = (E12ResultImpl*)malloc(sizeof(E12ResultImpl));
    if (!result_impl) {
        // Only finalize if we didn't cache it
        if (!stmt_cached) {
            sqlite3_finalize(stmt);
        }
        set_error(E12_ORM_ERROR, "Memory allocation failed");
        return E12_ORM_ERROR;
    }
    
    result_impl->stmt = stmt;
    result_impl->column_count = sqlite3_column_count(stmt);
    result_impl->has_row = false;
    result_impl->row_fetched = false;
    result_impl->owns_stmt = !stmt_cached;  // Only owns if not cached
    
    *out_result = (E12Result*)result_impl;
    return E12_ORM_OK;
}

void e12_stmt_cache_clear(E12StmtCache* cache) {
    if (!cache) return;
    
    E12StmtCacheImpl* cache_impl = (E12StmtCacheImpl*)cache;
    
    for (size_t i = 0; i < cache_impl->bucket_count; i++) {
        E12StmtCacheEntry* entry = cache_impl->buckets[i];
        while (entry) {
            E12StmtCacheEntry* next = entry->next;
            sqlite3_finalize(entry->stmt);
            free(entry->sql);
            free(entry);
            entry = next;
        }
        cache_impl->buckets[i] = NULL;
    }
    
    cache_impl->entry_count = 0;
}

void e12_stmt_cache_destroy(E12StmtCache* cache) {
    if (!cache) return;
    
    E12StmtCacheImpl* cache_impl = (E12StmtCacheImpl*)cache;
    
    // Clear all cached statements
    e12_stmt_cache_clear(cache);
    
    // Free buckets array and cache
    free(cache_impl->buckets);
    free(cache_impl);
}

void e12_stmt_cache_stats(E12StmtCache* cache, uint64_t* out_hits, uint64_t* out_misses) {
    if (!cache) {
        if (out_hits) *out_hits = 0;
        if (out_misses) *out_misses = 0;
        return;
    }
    
    E12StmtCacheImpl* cache_impl = (E12StmtCacheImpl*)cache;
    if (out_hits) *out_hits = cache_impl->hits;
    if (out_misses) *out_misses = cache_impl->misses;
}

// ============================================================================
// Error Handling
// ============================================================================

const char* e12_orm_get_last_error(void) {
    if (last_error_code == E12_ORM_OK) {
        return NULL;
    }
    return last_error_msg;
}

E12ORMErrorCode e12_orm_get_last_error_code(void) {
    return last_error_code;
}

