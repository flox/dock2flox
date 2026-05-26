# dock2flox

Convert your Dockerfiles and Docker Compose files into reproducible [Flox](https://flox.dev) environments.

Instead of building throwaway container images just to get a development shell, dock2flox reads your existing Docker artifacts and produces a `manifest.toml` that gives every engineer the same tools, versions, and services — on any machine, without containers.

## How It Works

dock2flox reads your Dockerfile and figures out what it's actually doing:

```
Dockerfile                          →  manifest.toml
─────────────────────────────────      ─────────────────────────────────
FROM python:3.11-slim                  python311 in [install]
RUN apt-get install curl git libpq     curl, git, postgresql in [install]
ENV APP_ENV=development                APP_ENV in [vars]
RUN pip install poetry pipenv uv       poetry, pipenv, uv in [install]
RUN curl ... nodejs.org ...            nodejs in [install]
RUN corepack enable yarn               yarn-berry in [install]
```

It doesn't just grep for package names. It runs your RUN commands through a **stubbed Bash interpreter** that expands variables, walks loops, and evaluates conditionals — without touching your host system:

```dockerfile
# dock2flox handles all of these correctly:
ENV PKGS="curl jq wget"
RUN apt-get install -y $PKGS                    # expands the variable
RUN for tool in yarn pnpm; do                   # walks the loop
      corepack enable "$tool"
    done
RUN case "$(uname -m)" in                       # picks the right branch
      x86_64) apt-get install -y amd64-tool ;;
      aarch64) apt-get install -y arm64-tool ;;
    esac
```

## Quick Start

```bash
# Preview what dock2flox would generate (doesn't write anything)
bin/dock2flox --dry-run

# Convert a specific Dockerfile
bin/dock2flox --dry-run path/to/Dockerfile

# Actually write the manifest
bin/dock2flox -o ./my-project Dockerfile

# Include Compose file (handles service boundary decisions)
bin/dock2flox --dry-run Dockerfile docker-compose.yml

# Validate package names against the Flox catalog
bin/dock2flox --dry-run --validate Dockerfile
```

If you don't specify files, dock2flox auto-detects `Dockerfile*` and `docker-compose*.yml` in the current directory.

## What You Get

The output is a complete Flox `manifest.toml` with:

- **`[install]`** — Every package your Dockerfile installs, mapped to Flox catalog names
- **`[vars]`** — Environment variables from ENV instructions
- **`[hook]`** — Activation logic: cache directory setup, venv creation, dependency installation
- **`[services]`** — Backing services (postgres, redis) if you choose `--services flox`
- **`REVIEW[...]` comments** — Anything dock2flox couldn't map with certainty, flagged for you to check

## What It Translates

| Your Dockerfile | Becomes |
|---|---|
| `FROM python:3.11` | `python3.pkg-path = "python311"` with version |
| `RUN apt-get install -y curl git` | `curl.pkg-path = "curl"` etc. |
| `RUN pip install uv pipenv` | `uv.pkg-path = "uv"` (native Flox package) |
| `RUN curl ... nodejs.org ...` (20 lines) | `nodejs.pkg-path = "nodejs"` (1 line) |
| `RUN npm install -g typescript` | Hook: `npm install -g typescript` |
| `RUN corepack enable yarn` | `yarn-berry.pkg-path = "yarn-berry"` |
| `ENV DATABASE_URL=...` | `DATABASE_URL = "..."` in [vars] |
| `RUN pip install -r requirements.txt` | Hook: `uv pip install -r requirements.txt` |
| `EXPOSE 8080` | `DOCK2FLOX_EXPOSED_PORTS = "8080"` metadata |
| `CMD ["node", "server.js"]` | Generated `[services].app` command |

## What It Skips (Intentionally)

These are container-packaging concerns that don't apply to development environments:

- `COPY` / `ADD` — your code is already in the checkout
- `USER` / `chown` — you're already you
- `rm -rf /var/lib/apt/lists/*` — no layer optimization needed
- `WORKDIR /app` — preserved as metadata, not enforced

## Handling Docker Compose Services

When dock2flox encounters services like postgres or redis in a Compose file, it asks what you want:

```bash
# Interactive: prompts you per-service
bin/dock2flox docker-compose.yml

# Keep services as external containers (just emit connection vars)
bin/dock2flox --services container docker-compose.yml

# Convert to Flox-managed services
bin/dock2flox --services flox docker-compose.yml
```

With `--services container`, you get connection variables (`PGHOST`, `PGPORT`, `REDIS_HOST`, etc.) so your code finds the existing containers. With `--services flox`, you get actual `[services]` definitions that Flox starts for you.

## Safety Model

dock2flox never executes your Dockerfile commands on your machine. The interpreter:

1. **Pre-scans** the RUN body with a Python safety gate (rejects path commands, eval, redirections, etc.)
2. **Stubs** every command — `apt-get`, `pip`, `curl`, `rm`, etc. are no-ops that just record what was called
3. **Isolates** execution with `PATH=/nonexistent` — nothing from your system can run
4. **Times out** after 5 seconds — infinite loops can't hang the tool
5. **Marks uncertainty** — anything it can't handle gets a `REVIEW[...]` comment instead of a wrong guess

## Package Confidence

Every package in the output has a confidence level:

- **EXACT** — found in the static mapping tables or validated by `flox search`
- **HIGH** — heuristic match (e.g., stripped `-dev` suffix → matched base package)
- **LOW** — best guess, marked with `# REVIEW:` comment
- **UNMAPPED** — no match found, commented out with `# UNMAPPED:` and a `flox search` hint

Run with `--validate` to use live `flox search` calls to upgrade LOW/UNMAPPED entries.

## Multi-Stage Dockerfiles

dock2flox automatically handles multi-stage builds. It resolves the **runtime inheritance chain** — when the final stage inherits from a named intermediate stage (e.g., `FROM ruby AS mastodon` where `ruby` is an earlier stage), dock2flox extracts packages from both the final stage and its ancestors. It excludes builder stages that are only referenced by `COPY --from`, and tracks ARG and ENV values across stages.

## Auto-Generated Cache Hooks

When dock2flox detects Python, Node.js, Rust, or Go packages, it automatically generates cache directory exports:

```toml
[hook]
on-activate = '''
export UV_CACHE_DIR="$FLOX_ENV_CACHE/uv"
export PIP_CACHE_DIR="$FLOX_ENV_CACHE/pip"
export npm_config_cache="$FLOX_ENV_CACHE/npm"
mkdir -p "$UV_CACHE_DIR" "$PIP_CACHE_DIR" "$npm_config_cache"
'''
```

## Python Package Placement (`--pip`)

Not every pip package belongs in `[install]`. dock2flox applies a **contract-scope calculus** — and gives you control over it:

```bash
bin/dock2flox --pip project     # (default) CLI tools + native extensions in [install]
bin/dock2flox --pip flox        # everything mapped goes into [install]
bin/dock2flox --pip cuda        # like project + ML packages from flox-cuda catalog
bin/dock2flox --pip requirements  # nothing in [install], all via uv hook
```

**The default calculus:** In `project` mode, dock2flox places packages in Flox `[install]` when their reproducibility depends on relationships that cross the Python/system boundary (CLI tools invoked from shell, native extensions linking to system libraries), and delegates everything else to the Python project graph (pyproject.toml / uv.lock). This is an opinionated default — use `--pip flox`, `--pip cuda`, or `--pip requirements` to override with your team's preferred boundary.

| `pip install ...` | `--pip=project` | `--pip=flox` | `--pip=cuda` | `--pip=requirements` |
|---|---|---|---|---|
| `ruff` | [install] (CLI tool) | [install] | [install] | uv hook |
| `psycopg2` | [install] (native ext) | [install] | [install] | uv hook |
| `flask` | uv hook (framework) | [install] | uv hook | uv hook |
| `torch` | uv hook | [install] | [install] flox-cuda/* | uv hook |
| `torchvision` | uv hook | [install] | [install] flox-cuda/* (dedup: torch omitted) | uv hook |

**CUDA dedup:** `flox-cuda/python3Packages.torchvision` includes torch transitively, so dock2flox omits a standalone torch entry when torchvision is present. Same for torchaudio. CUDA packages automatically get `systems = ["aarch64-linux", "x86_64-linux"]`.

## CLI Reference

```
dock2flox [OPTIONS] [FILE...]

OPTIONS:
    -i, --input FILE        Explicit input file (repeatable)
    -o, --output DIR        Output directory for manifest (default: ./)
    -n, --dry-run           Print manifest to stdout, do not write files
    -f, --force             Overwrite existing manifest without confirmation
        --validate          Verify package mappings via flox search
        --services MODE     Service handling: flox | container | prompt
        --pip MODE          Python packages: project | flox | cuda | requirements
        --verbose           Show mapping decisions on stderr
    -h, --help              Show usage

ENVIRONMENT VARIABLES:
    DOCK2FLOX_SERVICES      Override service mode (flox|container|prompt)
    DOCK2FLOX_PIP           Override pip mode (project|flox|cuda|requirements)
    DOCK2FLOX_VERBOSE       Set to 1 for verbose output
    DOCK2FLOX_RUN_TIMEOUT   Interpreter timeout per RUN (default: 5s)
    DOCK2FLOX_RUN_ARCH      Override architecture model (default: x86_64)
```

## Running Tests

```bash
tests/run_tests.sh          # 26 release-gate tests
python3 tests/run_tests.py  # Full 93-test suite
```

## Project Layout

```
bin/dock2flox                  CLI entrypoint
lib/
  core.sh                      Shared utilities, IR format, logging
  parser_dockerfile.sh         Dockerfile parser + interpreter dispatch
  run_shell_interpreter.sh     Stubbed Bash interpreter for RUN bodies
  shell_safe_subset.py         Pre-interpretation safety gate
  shell_safety_scan.py         Additional safety scanner
  parser_compose.sh            Compose parser (bash fallback)
  parser_compose.py            Compose parser (PyYAML, structured)
  mapper_packages.sh           apt/apk/pip → nixpkgs translation
  mapper_base_images.sh        FROM image:tag → package mapping
  emitter_toml.sh              IR → manifest.toml generation
  validator.sh                 flox search validation
data/
  apt_to_nixpkgs.map           Debian/Ubuntu package mappings
  apk_to_nixpkgs.map           Alpine package mappings
  pip_to_nixpkgs.map           PyPI → Flox catalog mappings
  base_images.map              Docker Hub images → packages
  known_installers.map         URL patterns (nodejs.org, rustup.rs, etc.)
  cache_hooks.map              Ecosystem → cache env vars
  cuda_packages.map            PyPI ML packages → flox-cuda paths + dedup rules
  package_conflicts.map        Known package file conflicts
  language_ecosystems.map      Language toolchain mappings
  corepack_tools.map           corepack enable → Flox packages
  skip_patterns.list           OCI boilerplate to ignore
```

## Adding Package Mappings

To teach dock2flox about new packages, add to the tab-separated files in `data/`:

```
# data/apt_to_nixpkgs.map
my-package	nixpkgs-equivalent	optional notes
```

Then run `tests/run_tests.sh` to verify.

## Limitations

- **Not a container replacement** — dock2flox produces development environments, not OCI images
- **Package coverage** — static mapping tables cover ~600 common apt and apk packages; uncommon ones need `--validate` or manual mapping
- **Compose orchestration** — networks, volumes, secrets, health checks are preserved as metadata but not enforced by Flox
- **RUN interpretation** — handles variables, loops, conditionals, and heredocs, but complex scripting (downloaded scripts, generated files) may still need review
- **devcontainer.json** — not yet supported
