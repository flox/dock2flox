Flox hosts an [experimental repo](https://github.com/flox/dock2flox) that partially automates the process of inspecting and mapping Dockerfiles, Compose Files, and dev container configurations to Flox environments.

The scripts in this repo are a good starting point for automating the work of translating these artifacts to Flox primitives and semantics.

The **`dock2flox`** tool reads a Dockerfile and classifies each instruction. It resolves base images to Flox packages and, if applicable, pins them to specific versions. Right now, it maps system packages that get installed via **`apt-get`**, **`apk`**, or **`yum`** to their **`nixpkgs`** equivalents via static lookup tables. When a package isn't in the tables, the tool applies heuristic transforms (stripping `-dev` suffixes, `lib` prefixes, etc.) and flags the result for review. Running with `--validate` verifies heuristic mappings against the live Flox catalog via **`flox search`**, correcting mismatches automatically.

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

For multi-stage Dockerfiles, the tool resolves the runtime inheritance chain. When the final stage inherits from a named intermediate stage, dock2flox extracts packages from both. It excludes builder stages that are only referenced by `COPY --from`.

For Compose files, the tool extracts service definitions and presents a boundary decision: keep backing services as external containers (emitting connection variables like `PGHOST` and `PGPORT`), or convert them to Flox-managed `[services]` definitions. When it cannot map something with certainty, it emits a `REVIEW[...]` comment at the top of the generated manifest rather than guessing.

A typical conversion looks like this:

```
Dockerfile                                  manifest.toml
──────────────────────────────────────      ──────────────────────────────────────
FROM python:3.11-slim                       python3.pkg-path = "python311"
RUN apt-get install curl git libpq-dev      curl, git, postgresql in [install]
ENV APP_ENV=development                     APP_ENV = "development" in [vars]
RUN pip install ruff psycopg2 flask         ruff, psycopg2 in [install]
                                            flask via uv hook
RUN curl ... nodejs.org ... (20 lines)      nodejs.pkg-path = "nodejs"
```

The output is a starting point, not a finished product. Teams should review the generated manifest, adjust package choices, and verify the environment with `flox activate` before committing it alongside the repo.
