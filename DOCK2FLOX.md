Flox hosts an [experimental repo](https://github.com/flox/dock2flox) that partially automates the process of inspecting and mapping Dockerfiles, Compose Files, and dev container configurations to Flox environments.

The scripts in this repo are a good starting point for automating the work of translating these artifacts to Flox primitives and semantics.

The **`dock2flox`** tool reads a Dockerfile and classifies each instruction. It resolves base images to Flox packages and, if applicable, pins them to specific versions. Right now, it maps system packages that get installed via **`apt-get`**, **`apk`**, or **`yum`** to their **`nixpkgs`** equivalents via static lookup tables covering ~600 common packages. When a package isn't in the tables, the tool applies heuristic transforms (stripping `-dev` suffixes, `lib` prefixes, etc.) and flags the result for review. Running with `--validate` verifies heuristic mappings against the live Flox catalog via **`flox search`**, correcting mismatches automatically.

The tool converts environment variables to **`[vars]`** entries and setup logic to **`[hook]`** activation scripts. It discards or preserves OCI-specific instructions like layer cleanup, **`COPY`**, **`USER`**, **`WORKDIR`** as review metadata, since they describe how a container is packaged, rather than the development environment itself.

This translation is not a line-by-line rewrite. The **dock2flox** tool analyzes **`RUN`** bodies via a stubbed Bash interpreter that expands variables, walks loops, and evaluates architecture-conditional branches … without executing anything on the host. This means it handles patterns like the following correctly:

```dockerfile
ENV PKGS="curl jq wget"
RUN apt-get install -y $PKGS

RUN for tool in yarn pnpm; do corepack enable "$tool"; done

RUN case "$(uname -m)" in
      x86_64) apt-get install -y amd64-tool ;;
      aarch64) apt-get install -y arm64-tool ;;
    esac
```

The tool gives Python packages special treatment. It distinguishes between packages that cross the Python/system boundary—CLI tools like `ruff` and `mypy`, native-extension packages like `psycopg2` that link against system libraries—and packages that _live inside_ the Python project graph. It declares the former in **`[install]`** and delegates the latter to tools like **`uv`** at activation time via the project's own **`requirements.txt`** or **`pyproject.toml`**. A `--pip` flag lets teams override this default: `--pip flox` places everything in `[install]`, `--pip cuda` adds CUDA-accelerated packages from the `flox-cuda` catalog, and `--pip requirements` delegates all Python dependencies to the project lockfile.

For multi-stage Dockerfiles, the tool resolves the runtime inheritance chain. When the final stage inherits from a named intermediate stage, dock2flox extracts packages from both. It excludes builder stages that only appear as `COPY --from` sources.

For Compose files, the tool extracts service definitions and presents a boundary decision: keep backing services as external containers (emitting connection variables like `PGHOST` and `PGPORT`), or convert them to Flox-managed `[services]` definitions. When it cannot map something with certainty, it emits a `REVIEW[...]` comment at the top of the generated manifest rather than guessing.

### Dockerfile example

Given a Rails application Dockerfile:

```dockerfile
FROM ruby:3.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpq-dev libvips curl git \
    nodejs npm postgresql-client \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g yarn

ENV RAILS_ENV=development
ENV DATABASE_URL=postgresql://localhost:5432/myapp

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .
EXPOSE 3000
CMD ["rails", "server", "-b", "0.0.0.0"]
```

Running `dock2flox --dry-run Dockerfile` produces:

```toml
schema-version = "1.11.0"

[install]
bundler.pkg-path = "bundler"
curl.pkg-path = "curl"
gcc.pkg-path = "gcc"
git.pkg-path = "git"
nodejs.pkg-path = "nodejs"
postgresql.pkg-path = "postgresql"
ruby.pkg-path = "ruby"
ruby.version = "3.3"
vips.pkg-path = "vips"

[vars]
DATABASE_URL = "postgresql://localhost:5432/myapp"
RAILS_ENV = "development"

[hook]
on-activate = '''
export npm_config_cache="$FLOX_ENV_CACHE/npm"
export GEM_HOME="$FLOX_ENV_CACHE/gems"
export BUNDLE_PATH="$FLOX_ENV_CACHE/bundle"
mkdir -p "$FLOX_ENV_CACHE/npm" "$FLOX_ENV_CACHE/gems" "$FLOX_ENV_CACHE/bundle"

npm install -g yarn
if [ -f Gemfile ]; then
  bundle config set path "${BUNDLE_PATH:-$FLOX_ENV_CACHE/bundle}" >/dev/null 2>&1 || true
  bundle install
fi

cd "$FLOX_ENV_PROJECT"
'''

[services]
app.command = "rails server -b 0.0.0.0"
```

The tool mapped `build-essential` to `gcc`, `libpq-dev` to `postgresql`, `libvips` to `vips`, resolved `ruby:3.3-slim` to a version-pinned Ruby package, detected `npm install -g yarn` as a lifecycle hook, auto-generated cache directories for Node.js and Bundler, and converted the `CMD` into a runnable service definition.

**What it missed:** The `npm install -g yarn` command stays as a hook rather than mapping to the `yarn-berry` Flox package. A team reviewing this manifest might replace the hook with `yarn-berry.pkg-path = "yarn-berry"` in `[install]`. The cleaned example above omits the `DOCK2FLOX_CONTAINER_WORKDIR` and `DOCK2FLOX_EXPOSED_PORTS` metadata variables for brevity; the raw output includes them to preserve the original Dockerfile's runtime intent for review.

### Compose file example

Given a Compose file that defines a web service with PostgreSQL and Redis:

```yaml
services:
  web:
    build: .
    ports:
      - "3000:3000"
    environment:
      - DATABASE_URL=postgresql://postgres:secret@db:5432/myapp
      - REDIS_URL=redis://cache:6379/0
      - RAILS_ENV=development
    depends_on:
      - db
      - cache

  db:
    image: postgres:16
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=secret
      - POSTGRES_DB=myapp
    volumes:
      - pgdata:/var/lib/postgresql/data

  cache:
    image: redis:7-alpine
    ports:
      - "6379:6379"

volumes:
  pgdata:
```

Running `dock2flox --services container --dry-run docker-compose.yml` produces connection variables for the backing services and preserves all Compose metadata as `DOCK2FLOX_COMPOSE_*` variables:

```toml
schema-version = "1.11.0"

[vars]
DATABASE_URL = "postgresql://postgres:secret@db:5432/myapp"
PGHOST = "localhost"
PGPORT = "5432"
POSTGRES_DB = "myapp"
POSTGRES_PASSWORD = "secret"
POSTGRES_USER = "postgres"
RAILS_ENV = "development"
REDIS_HOST = "localhost"
REDIS_PORT = "6379"
REDIS_URL = "redis://cache:6379/0"
```

The tool extracted environment variables from all three services, generated `PGHOST`/`PGPORT` and `REDIS_HOST`/`REDIS_PORT` connection variables for the backing services, and kept both PostgreSQL and Redis as external containers. The full output also includes `DOCK2FLOX_COMPOSE_DB_IMAGE`, `DOCK2FLOX_COMPOSE_CACHE_IMAGE`, volume mappings, port specs, and `REVIEW[compose-*]` comments for networking, orchestration, and volumes — all preserved as reviewable metadata.

**What it missed:** The `DATABASE_URL` still references `db` (the Compose service hostname) rather than `localhost`. A team reviewing this manifest would update it to `postgresql://postgres:secret@localhost:5432/myapp` to match the local connection. The `POSTGRES_PASSWORD=secret` value is a development placeholder; teams should replace it with a secret reference or env-var injection for anything beyond local dev.

**Two options for managing backing services:**

The example above emits connection variables only — teams start and stop backing containers outside Flox (via `docker compose up -d` / `docker compose down`). This keeps Flox and Docker Compose fully independent.

Alternatively, teams can wrap Compose services in Flox service definitions so that `flox activate -s` starts the containers and `flox services stop` tears them down. The Compose file stays as the source of truth for container configuration; Flox manages the lifecycle:

```toml
[services.db]
command = "docker compose up -d db"
is-daemon = true
shutdown.command = "docker compose stop db && docker compose rm -f db"

[services.cache]
command = "docker compose up -d cache"
is-daemon = true
shutdown.command = "docker compose stop cache && docker compose rm -f cache"
```

This pattern lets engineers run `flox activate -s` and get both the project runtime and its backing services in one step. To preserve containers between sessions, remove the `docker compose rm -f ...` from the shutdown commands. Either pattern works — the choice depends on whether the team wants Flox to own the full lifecycle or just the project environment.

The output is a starting point, not a finished product. Teams should review the generated manifest, adjust package choices, and verify the environment with `flox activate` before committing it alongside the repo.
