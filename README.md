# Engine12

A backend framework for Zig, designed for building high-performance web applications and APIs.

## Quick Start

**Option 1: Use CLI Tool (Recommended)**

```bash
# Create a new project with recommended structure
e12 new myapp
cd myapp
zig build run
```

**Option 2: Manual Setup**

```zig
const std = @import("std");
const Engine12 = @import("engine12");

fn handleRoot(req: *Engine12.Request) Engine12.Response {
    _ = req;
    return Engine12.Response.text("Hello, World!");
}

pub fn main() !void {
    var app = try Engine12.initDevelopment();
    defer app.deinit();

    try app.get("/", handleRoot);
    try app.listen();  // Blocks until shutdown
}
```

**Option 3: Environment-Based Configuration (Cloud-Ready)**

```zig
const Engine12 = @import("engine12");

pub fn main() !void {
    // Auto-configure from .env file and system environment variables
    var app = try Engine12.initFromEnv();
    defer app.deinit();

    try app.get("/", handleRoot);
    try app.listen();
}
```

## Installation

### Step 1: Fetch the package

Run `zig fetch` to add Engine12 to your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/ooyeku/engine12.git"
```

This will automatically add the dependency with the correct hash to your `build.zig.zon` file.

Alternatively, you can manually add it to your `build.zig.zon`:

```zig
.dependencies = .{
    .engine12 = .{
        .url = "git+https://github.com/ooyeku/engine12.git",
        .hash = "...", // Run `zig fetch` to get the hash
    },
},
```

### Step 2: Add to your build.zig

Add the dependency and module to your `build.zig`:

```zig
const engine12_dep = b.dependency("engine12", .{
    .target = target,
    .optimize = optimize,
});

exe.addModule("engine12", engine12_dep.module("engine12"));
```

SQLite is bundled with Engine12, so the ORM works out of the box with no additional setup required.

## Environment Configuration

Engine12 provides a centralized configuration system for cloud-ready deployments. All Engine12-specific environment variables use the `E12_` prefix.

### Quick Setup

1. Copy `.env.example` to `.env` in your project root:
   ```bash
   cp .env.example .env
   ```

2. Use `initFromEnv()` in your application:
   ```zig
   var app = try Engine12.initFromEnv();
   ```

### Environment Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `E12_ENV` | enum | `development` | Environment: `development`, `staging`, `production` |
| `E12_HOST` | string | `127.0.0.1` | Server bind address |
| `E12_PORT` | u16 | `8080` | Server port |
| `E12_WORKERS` | u16 | `12` | Worker thread count |
| `E12_LOG_LEVEL` | enum | `debug` | Log level: `debug`, `info`, `warn`, `error` |
| `E12_LOG_REQUESTS` | bool | `true` | Enable request logging |
| `E12_DB_DRIVER` | enum | `sqlite` | Database driver: `sqlite`, `postgresql` |
| `E12_DB_PATH` | string | `app.db` | SQLite database path |
| `E12_DB_HOST` | string | `127.0.0.1` | PostgreSQL host |
| `E12_DB_PORT` | u16 | `5432` | PostgreSQL port |
| `E12_DB_NAME` | string | - | PostgreSQL database name |
| `E12_DB_USER` | string | - | PostgreSQL username |
| `E12_DB_PASSWORD` | string | - | PostgreSQL password |
| `E12_CACHE_ENABLED` | bool | `true` | Enable response caching |
| `E12_CACHE_TTL` | u32 | `60000` | Cache TTL in milliseconds |
| `E12_SECRET_KEY` | string | - | Application secret (required in production) |

#### Resource Limits (Advanced)

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `E12_MAX_ROUTES` | usize | `5000` | Maximum HTTP routes |
| `E12_MAX_BACKGROUND_WORKERS` | usize | `32` | Maximum background tasks |
| `E12_MAX_HEALTH_CHECKS` | usize | `8` | Maximum health check functions |
| `E12_MAX_STATIC_ROUTES` | usize | `500` | Maximum static file routes |
| `E12_MAX_WS_ROUTES` | usize | `1000` | Maximum WebSocket routes |
| `E12_MAX_QUEUE_SIZE` | usize | `4096` | Connection queue size |
| `E12_MAX_MIDDLEWARE` | usize | `16` | Maximum middleware functions |
| `E12_MAX_CONTEXT_ENTRIES` | usize | `16` | Maximum request context entries |
| `E12_MAX_ROUTE_PARAMS` | usize | `8` | Maximum route parameters |
| `E12_MAX_VALVES` | usize | `32` | Maximum valve (plugin) count |

### Example .env File

```env
# Application
E12_ENV=development
E12_HOST=127.0.0.1
E12_PORT=8080

# Database (PostgreSQL)
E12_DB_DRIVER=postgresql
E12_DB_HOST=localhost
E12_DB_PORT=5432
E12_DB_NAME=myapp
E12_DB_USER=postgres
E12_DB_PASSWORD=secret

# Logging
E12_LOG_LEVEL=debug
E12_LOG_REQUESTS=true

# Security
E12_SECRET_KEY=your-secret-key-here
```

### Layered Configuration

- **System environment variables** take precedence over `.env` file values
- **Legacy variables** (`PGHOST`, `PGUSER`, `DB_DRIVER`, etc.) are supported for backward compatibility
- The `.env` file is optional and silently ignored if missing

> **For detailed configuration guide, see [docs/configuration.md](docs/configuration.md)**
>
> The configuration guide includes:
> - Complete documentation of all environment variables
> - Resource limits tuning guide
> - Environment-specific best practices
> - Performance tuning recommendations
> - Example configurations for different deployment scenarios

## Features

- **High Performance** - Multi-threaded request handling with configurable worker threads (default: 12)
- **Environment Configuration** - Centralized `E12_*` prefixed env vars with `.env` file support for cloud deployment
- **HTTP Routing** - GET, POST, PUT, DELETE, PATCH with route parameters
- **Server Configuration** - Configurable host, port, timeouts, and worker threads via `configure()` or environment
- **WebSocket Support** - Real-time bidirectional communication with room management
- **HTMX Integration** - Zero-configuration HTMX support with form parsing, error helpers, and response builders (auto-enabled in development)
- **Hot Reloading** - Automatic template and static file reloading in development mode
- **Auto-Discovery** - Automatic migration, static file, and template discovery to reduce boilerplate
- **Project Scaffolding** - CLI tool (`e12 new`) to generate projects with recommended structure
- **Structured Logging** - JSON and human-readable logging with multiple destinations (stdout, file, syslog)
- **Middleware System** - Pre-request and response middleware chains
- **SQLite ORM** - Type-safe database operations with automatic table pluralization, upsert support, managed memory, and parameter binding for SQL injection prevention
- **PostgreSQL Support** - Full PostgreSQL integration with connection pooling
- **Template Engine** - Server-side HTML rendering
- **Request/Response API** - Clean, memory-safe HTTP handling with struct-to-JSON convenience methods
- **Rate Limiting** - Per-route rate limiting
- **CSRF Protection** - Built-in CSRF token validation
- **Metrics & Health Checks** - Request timing and health monitoring
- **Background Tasks** - Periodic and one-time task scheduling
- **Static File Serving** - Serve static assets
- **OpenAPI/Swagger Documentation** - Automatic API documentation generation with Swagger UI
- **CSS-in-Zig** - Type-safe CSS generation with design tokens, animations, and responsive styles


- **Cross-Platform** - Fully compatible with Linux, macOS, and Windows.

## Cross-Compilation

Engine12 supports cross-compilation to Windows and other platforms out of the box.

```bash
# Build for Windows x86_64
zig build -Dtarget=x86_64-windows
```

## Documentation

- [API Reference](docs/api-reference.md) - Complete API documentation
- [CSS-in-Zig](docs/css.md) - Type-safe CSS generation guide
- [Tutorial](docs/tutorial.md) - Step-by-step guide to building your first app
- [Architecture Guide](docs/architecture.md) - System design and architecture
- [Troubleshooting](docs/troubleshooting.md) - Common issues and solutions

## Example

See the [todo app example](examples/todo/src/main.zig) for a complete working application demonstrating:

- Database setup and migrations
- CRUD operations with the ORM
- Template rendering
- Route handlers
- CSS-in-Zig styling (see [styles.zig](examples/todo/src/styles.zig))
- Frontend integration

## Requirements

- Zig 0.15.1 or later

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions welcome! Please see our contributing guidelines.
