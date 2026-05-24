# dock2flox

Convert Dockerfiles and Docker Compose files into [Flox](https://flox.dev) environment manifests.

dock2flox automates **Playbook 3** from the [Flox Platform Engineering Guide](GUIDANCE.md): mapping Docker/Compose artifacts into declared Flox environments. It extracts the runtime contract implicit in your Dockerfiles and translates it into Flox's declarative `manifest.toml` format.

## Quick Start

```bash
# Auto-detect Dockerfile/Compose in current directory
bin/dock2flox --dry-run

# Convert a specific Dockerfile
bin/dock2flox --dry-run path/to/Dockerfile

# Convert and write manifest.toml
bin/dock2flox -o ./my-project path/to/Dockerfile

# Validate mappings against flox search
bin/dock2flox --dry-run --validate Dockerfile
```

## What It Does

Given a Dockerfile like:

```dockerfile
FROM python:3.11-slim
RUN apt-get update && apt-get install -y curl git libpq-dev pkg-config
ENV APP_ENV=development
ENV PGHOST=localhost
```

dock2flox produces:

```toml
schema-version = "1.11.0"

[install]
curl.pkg-path = "curl"
git.pkg-path = "git"
pkg-config.pkg-path = "pkg-config"
postgresql.pkg-path = "postgresql"
python3.pkg-path = "python311"
python3.version = "3.11"

[vars]
APP_ENV = "development"
PGHOST = "localhost"
```

## Mapping Rules

| Docker Artifact | Flox Manifest |
|---|---|
| `FROM image:tag` | `[install]` with version |
| `RUN apt-get install` / `apk add` | `[install]` packages |
| `ENV KEY=VALUE` (literal) | `[vars]` |
| `ENV PATH=...` (derived) | `[hook]` export |
| `RUN pip install` | `[hook]` comment |
| `RUN mkdir -p` (setup) | `[hook]` line |
| Compose `environment` | `[vars]` |
| Compose services (postgres, redis) | Connection vars or `[services]` |

**Deliberately omitted** (OCI-specific):
- `COPY`, `WORKDIR`, `USER`, `chown`
- Layer cleanup (`rm -rf /var/lib/apt/lists/*`)
- `CMD` / `ENTRYPOINT`
- Container networking (`ports`, `depends_on`)

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
                            (default: prompt if TTY, container otherwise)
        --verbose           Show mapping decisions on stderr
    -h, --help              Show usage
```

## Service Boundary Decision

When processing Compose files with backing services (postgres, redis, etc.), dock2flox handles the boundary decision contextually:

- **Interactive (TTY)**: Prompts per-service whether to convert to Flox `[services]` or keep as external containers
- **Non-interactive**: Defaults to keeping services as containers (emits connection vars)
- **Flag override**: `--services=flox` or `--services=container`
- **Env var override**: `DOCK2FLOX_SERVICES=flox|container|prompt`

## Package Mapping Strategy

dock2flox uses a 3-layer resolution strategy:

1. **Static tables** (`data/apt_to_nixpkgs.map`, `data/apk_to_nixpkgs.map`) — ~100 known apt/apk-to-nixpkgs mappings
2. **Heuristics** — strips `-dev` suffixes, `lib` prefixes, handles `python3-*` namespacing, version-suffixed packages
3. **Validation** (`--validate`) — live `flox search` calls to verify unmapped/heuristic packages

Each mapping gets a confidence score:
- `EXACT` — found in static map or validated by flox search
- `HIGH` — heuristic match or close flox search result
- `LOW` — multiple candidates, best guess selected
- `UNMAPPED` — no match found (emitted as commented-out TOML)

## Multi-Stage Dockerfile Support

dock2flox automatically handles multi-stage builds:
- Only the **final stage** is converted (runtime dependencies)
- Intermediate build stages are skipped with SKIP records
- `ARG` values are tracked and substituted throughout

## Project Structure

```
bin/dock2flox              # Master entrypoint
lib/
  core.sh                  # Shared utilities, logging, temp files
  parser_dockerfile.sh     # Dockerfile parser
  parser_compose.sh        # Docker Compose parser
  mapper_packages.sh       # apt/apk -> nixpkgs translation
  mapper_base_images.sh    # FROM image -> package mapping
  emitter_toml.sh          # IR -> manifest.toml generation
  validator.sh             # flox search validation
data/
  apt_to_nixpkgs.map       # Static apt package mappings
  apk_to_nixpkgs.map       # Static apk package mappings
  base_images.map          # Base image -> package mappings
  skip_patterns.list       # Patterns to ignore
tests/
  run_tests.sh             # Test runner
  fixtures/                # Test Dockerfiles and Compose files
```

## Running Tests

```bash
tests/run_tests.sh
```

## Limitations

- **YAML parsing**: The Compose parser uses line-by-line parsing, not a full YAML parser. Complex YAML features (anchors, multi-line strings, flow mappings) may not parse correctly.
- **Package coverage**: The static mapping tables cover ~100 common packages. Uncommon packages will be marked UNMAPPED.
- **pip/npm packages**: Language-level dependencies (pip, npm) are emitted as hook comments, not translated to nixpkgs equivalents.
- **devcontainer.json**: Not yet implemented.
- **Version mapping**: Some version formats may not translate perfectly to Flox version constraints.

## Contributing

To add package mappings, edit the tab-separated files in `data/`:

```
# Format: distro_name<TAB>nixpkgs_path<TAB>optional_notes
my-package	nixpkgs-equivalent	any notes here
```

Then run `tests/run_tests.sh` to verify nothing breaks.
