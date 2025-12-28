# Engine12 Configuration Guide

Engine12 uses environment variables with the `E12_` prefix for all configuration. Configuration can be set via:
- System environment variables
- `.env` file in the current directory
- Custom `.env` file path

System environment variables take precedence over `.env` file values.

## Table of Contents
- [Core Configuration](#core-configuration)
- [Server Configuration](#server-configuration)
- [Database Configuration](#database-configuration)
- [Logging Configuration](#logging-configuration)
- [Cache Configuration](#cache-configuration)
- [Resource Limits](#resource-limits)
- [Security Configuration](#security-configuration)
- [Examples](#examples)

---

## Core Configuration

### `E12_ENV`
- **Type:** `development` | `staging` | `production`
- **Default:** `development`
- **Description:** Application environment mode
- **Impact:** 
  - In `development`: Hot reload enabled, debug logging, HTMX injected
  - In `production`: Optimized settings, info-level logging
  - In `staging`: Test environment settings

```bash
E12_ENV=production
```

---

## Server Configuration

### `E12_HOST`
- **Type:** String (IP address)
- **Default:** `127.0.0.1`
- **Description:** Server bind address

```bash
E12_HOST=0.0.0.0  # Listen on all interfaces
```

### `E12_PORT`
- **Type:** Integer (1-65535)
- **Default:** `8080`
- **Description:** Server port

```bash
E12_PORT=3000
```

### `E12_WORKERS`
- **Type:** Integer
- **Default:** `12` (development), `32` (production)
- **Description:** Number of worker threads for handling connections

```bash
E12_WORKERS=16
```

### `E12_READ_TIMEOUT`
- **Type:** Integer (milliseconds)
- **Default:** `10000` (10 seconds)
- **Description:** Socket read timeout

```bash
E12_READ_TIMEOUT=15000  # 15 seconds
```

### `E12_WRITE_TIMEOUT`
- **Type:** Integer (milliseconds)
- **Default:** `10000` (10 seconds)
- **Description:** Socket write timeout

```bash
E12_WRITE_TIMEOUT=15000  # 15 seconds
```

### `E12_MAX_BODY_SIZE`
- **Type:** Integer (bytes)
- **Default:** `10485760` (10 MB)
- **Description:** Maximum request body size

```bash
E12_MAX_BODY_SIZE=52428800  # 50 MB
```

---

## Database Configuration

### `E12_DB_DRIVER`
- **Type:** `sqlite` | `postgresql`
- **Default:** `sqlite`
- **Description:** Database driver to use

```bash
E12_DB_DRIVER=postgresql
```

### SQLite Configuration

#### `E12_DB_PATH`
- **Type:** String (file path)
- **Default:** `app.db`
- **Description:** SQLite database file path

```bash
E12_DB_PATH=/var/lib/myapp/database.db
```

### PostgreSQL Configuration

#### `E12_DB_HOST`
- **Type:** String (hostname or IP)
- **Default:** `127.0.0.1`
- **Description:** PostgreSQL server host

```bash
E12_DB_HOST=postgres.example.com
```

#### `E12_DB_PORT`
- **Type:** Integer
- **Default:** `5432`
- **Description:** PostgreSQL server port

```bash
E12_DB_PORT=5432
```

#### `E12_DB_NAME`
- **Type:** String
- **Default:** None
- **Required:** Yes (in production with PostgreSQL)
- **Description:** Database name

```bash
E12_DB_NAME=myapp_production
```

#### `E12_DB_USER`
- **Type:** String
- **Default:** None
- **Required:** Yes (in production with PostgreSQL)
- **Description:** Database user

```bash
E12_DB_USER=myapp_user
```

#### `E12_DB_PASSWORD`
- **Type:** String
- **Default:** None
- **Description:** Database password

```bash
E12_DB_PASSWORD=secure_password_here
```

---

## Logging Configuration

### `E12_LOG_LEVEL`
- **Type:** `debug` | `info` | `warn` | `error`
- **Default:** `debug` (development), `info` (production)
- **Description:** Minimum log level to output

```bash
E12_LOG_LEVEL=info
```

### `E12_LOG_REQUESTS`
- **Type:** Boolean (`true` | `false`)
- **Default:** `true`
- **Description:** Enable request logging

```bash
E12_LOG_REQUESTS=true
```

---

## Cache Configuration

### `E12_CACHE_ENABLED`
- **Type:** Boolean
- **Default:** `true`
- **Description:** Enable response caching

```bash
E12_CACHE_ENABLED=true
```

### `E12_CACHE_TTL`
- **Type:** Integer (milliseconds)
- **Default:** `60000` (1 minute)
- **Description:** Default cache time-to-live

```bash
E12_CACHE_TTL=300000  # 5 minutes
```

---

## Resource Limits

These limits control memory allocation and prevent resource exhaustion. Adjust based on your application's needs.

### `E12_MAX_ROUTES`
- **Type:** Integer
- **Default:** `5000`
- **Description:** Maximum number of HTTP routes
- **When to increase:** Large APIs with thousands of endpoints
- **Memory impact:** ~80 bytes per route

```bash
E12_MAX_ROUTES=10000
```

### `E12_MAX_BACKGROUND_WORKERS`
- **Type:** Integer
- **Default:** `32`
- **Description:** Maximum number of background worker tasks
- **When to increase:** Many scheduled jobs or background processes
- **Memory impact:** Minimal per worker

```bash
E12_MAX_BACKGROUND_WORKERS=64
```

### `E12_MAX_HEALTH_CHECKS`
- **Type:** Integer
- **Default:** `8`
- **Description:** Maximum number of health check functions
- **When to increase:** Complex health monitoring with many dependencies

```bash
E12_MAX_HEALTH_CHECKS=16
```

### `E12_MAX_STATIC_ROUTES`
- **Type:** Integer
- **Default:** `500`
- **Description:** Maximum number of static file route handlers
- **When to increase:** Serving many static directories

```bash
E12_MAX_STATIC_ROUTES=1000
```

### `E12_MAX_WS_ROUTES`
- **Type:** Integer
- **Default:** `1000`
- **Description:** Maximum number of WebSocket routes
- **When to increase:** Real-time applications with many WS endpoints

```bash
E12_MAX_WS_ROUTES=2000
```

### `E12_MAX_QUEUE_SIZE`
- **Type:** Integer
- **Default:** `4096`
- **Description:** Connection queue size for worker threads
- **When to increase:** High-traffic applications with many concurrent connections
- **Memory impact:** ~8 bytes per queue slot

```bash
E12_MAX_QUEUE_SIZE=8192
```

### `E12_MAX_MIDDLEWARE`
- **Type:** Integer
- **Default:** `16`
- **Description:** Maximum middleware functions in the chain
- **When to increase:** Complex middleware stacks

```bash
E12_MAX_MIDDLEWARE=32
```

### `E12_MAX_CONTEXT_ENTRIES`
- **Type:** Integer
- **Default:** `16`
- **Description:** Maximum context entries per request
- **When to increase:** Storing many values in request context
- **Memory impact:** Per-request allocation

```bash
E12_MAX_CONTEXT_ENTRIES=32
```

### `E12_MAX_ROUTE_PARAMS`
- **Type:** Integer
- **Default:** `8`
- **Description:** Maximum route parameters per request (e.g., `/user/:id/:action`)
- **When to increase:** Routes with many parameters

```bash
E12_MAX_ROUTE_PARAMS=16
```

### `E12_MAX_VALVES`
- **Type:** Integer
- **Default:** `32`
- **Description:** Maximum number of registered valves (plugins)
- **When to increase:** Plugin-heavy applications

```bash
E12_MAX_VALVES=64
```

---

## Security Configuration

### `E12_SECRET_KEY`
- **Type:** String (base64 or hex)
- **Default:** None
- **Required:** Recommended in production
- **Description:** Secret key for signing sessions, tokens, etc.

```bash
E12_SECRET_KEY=your-256-bit-secret-key-here
```

**⚠️ Warning:** This should be a long, random string in production.

---

## Examples

### Development .env
```bash
E12_ENV=development
E12_PORT=3000
E12_DB_DRIVER=sqlite
E12_DB_PATH=dev.db
E12_LOG_LEVEL=debug
E12_LOG_REQUESTS=true
```

### Production .env
```bash
E12_ENV=production
E12_HOST=0.0.0.0
E12_PORT=8080
E12_WORKERS=32

E12_DB_DRIVER=postgresql
E12_DB_HOST=db.internal.example.com
E12_DB_PORT=5432
E12_DB_NAME=myapp_prod
E12_DB_USER=myapp_user
E12_DB_PASSWORD=${DB_PASSWORD}

E12_LOG_LEVEL=info
E12_LOG_REQUESTS=false

E12_CACHE_ENABLED=true
E12_CACHE_TTL=300000

E12_SECRET_KEY=${SECRET_KEY}

# Increased limits for high-traffic app
E12_MAX_ROUTES=10000
E12_MAX_QUEUE_SIZE=8192
E12_MAX_BACKGROUND_WORKERS=64
```

### High-Volume API .env
```bash
E12_ENV=production
E12_WORKERS=64
E12_MAX_QUEUE_SIZE=16384
E12_MAX_ROUTES=20000
E12_MAX_MIDDLEWARE=32
```

---

## Loading Configuration in Code

```zig
const engine12 = @import("engine12");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    // Load from .env and environment variables
    var app = try engine12.Engine12.initFromEnv();
    defer app.deinit();
    
    // Configuration is automatically applied
    try app.listen();
}
```

---

## Environment-Specific Best Practices

### Development
- Use SQLite for simplicity
- Enable debug logging
- Keep defaults for limits
- Hot reload is automatically enabled

### Staging
- Mirror production database type
- Use info-level logging
- Test with production-like limits

### Production
- Use PostgreSQL for scalability
- Set `E12_SECRET_KEY`
- Disable request logging for performance
- Increase limits based on load testing
- Set appropriate timeouts
- Use environment variables, not .env files for secrets

---

## Performance Tuning

### High Concurrency
```bash
E12_WORKERS=64
E12_MAX_QUEUE_SIZE=16384
E12_READ_TIMEOUT=30000
E12_WRITE_TIMEOUT=30000
```

### Low Latency
```bash
E12_WORKERS=16
E12_CACHE_ENABLED=true
E12_CACHE_TTL=60000
E12_MAX_QUEUE_SIZE=2048
```

### Memory Constrained
```bash
E12_MAX_ROUTES=1000
E12_MAX_QUEUE_SIZE=1024
E12_MAX_BACKGROUND_WORKERS=8
E12_MAX_WS_ROUTES=100
```
