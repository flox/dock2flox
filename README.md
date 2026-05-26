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
| `RUN apt-get install` / `apk add` | `[install]` packages, parsed through a stubbed Bash interpreter when possible |
| `ENV KEY=VALUE` (literal) | `[vars]` |
| `ENV PATH=...` (derived) | `[hook]` export |
| `ENV POETRY_HOME=/usr/local` | `[hook]` export to `$FLOX_ENV` |
| `RUN pip install -r requirements.txt` | `[install] uv` plus active `[hook]` `uv pip install --quiet -r ...` |
| `RUN pip install .` / `pip install -e .` | `[install] uv` plus active `[hook]` `uv sync --quiet` when `pyproject.toml` exists |
| `RUN mkdir -p` (setup) | `[hook]` line |
| `RUN corepack enable yarn` | `[install] yarn-berry` with no redundant hook |
| `RUN npm/yarn/pnpm install` | `[install]` Node/package-manager tools plus lockfile-aware activation hooks |
| `RUN bundle install` / `gem install bundler` | `[install]` Ruby/Bundler plus Gemfile activation hooks |
| `RUN composer install` | `[install]` PHP/Composer plus composer.json activation hooks |
| `RUN mvn ...` / `gradle ...` | `[install]` JDK/build tool plus gated build hooks |
| `RUN cargo ...` / `go ...` | `[install]` Rust/Go toolchains plus module/build hooks |
| `WORKDIR` | `DOCK2FLOX_CONTAINER_WORKDIR` metadata plus best-effort activation directory mapping |
| `CMD` / `ENTRYPOINT` | `DOCK2FLOX_CONTAINER_*` metadata plus a generated `app` service command |
| `EXPOSE` | `DOCK2FLOX_EXPOSED_PORTS` metadata and review hook comment |
| `USER`, `VOLUME`, `HEALTHCHECK`, `STOPSIGNAL`, `SHELL` | `DOCK2FLOX_*` metadata and review hook comments |
| `COPY` / `ADD` | Review hook comments preserving source/destination, build-stage, ownership, and remote-fetch concerns |
| Compose `environment` / `env_file` | service-scoped `DOCK2FLOX_COMPOSE_*` vars plus compatible simple `[vars]` |
| Compose `ports`, `expose`, `volumes`, `secrets`, `configs`, `healthcheck`, `depends_on`, `profiles`, `networks` | preserved as reviewable metadata and `REVIEW[compose-*]` comments |
| Compose services (postgres, redis) | Connection vars or `[services]` |

**Still intentionally not reproduced as image layers**:
- File ownership/user switching (`USER`, `COPY --chown`, `chown`) is preserved as metadata because Flox activation does not switch Unix users.
- Layer filesystem construction (`COPY`, `ADD`, build-stage artifacts) is preserved as reviewable manifest content; project files should usually come from the checkout, and build-stage artifacts should become explicit build steps.
- Container port publication is preserved as metadata; Flox does not publish ports by itself.
- Layer cleanup (`rm -rf /var/lib/apt/lists/*`) remains ignored because it optimizes image size rather than the development environment.

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


## Compose Semantics

Compose files are parsed with a structured Python/PyYAML helper when available.
That path resolves YAML anchors and merge keys before emitting dock2flox IR, so
shared service definitions such as `x-common: &common` and `<<: *common` are
preserved in the generated manifest.

For each service, dock2flox now emits service-scoped metadata variables using
`DOCK2FLOX_COMPOSE_<SERVICE>_*` names for image/build settings, command,
entrypoint, environment, env files, ports, exposed ports, volumes, secrets,
configs, healthchecks, dependencies, networks, profiles, labels, and common
runtime fields. It also emits `REVIEW[compose-*]` comments for behavior Flox
does not reproduce directly, such as orchestration ordering, healthcheck
enforcement, Docker networking, named volumes, secrets/configs, and image build
execution.

If Python or PyYAML is unavailable, dock2flox falls back to a conservative
Bash parser and marks advanced Compose semantics for review instead of silently
dropping them.

## Service Boundary Decision

When processing Compose files with backing services (postgres, redis, etc.), dock2flox handles the boundary decision contextually:

- **Interactive (TTY)**: Prompts per-service whether to convert to Flox `[services]` or keep as external containers
- **Non-interactive**: Defaults to keeping services as containers (emits connection vars)
- **Flag override**: `--services=flox` or `--services=container`
- **Env var override**: `DOCK2FLOX_SERVICES=flox|container|prompt`

## RUN Shell Interpretation

Dockerfile `RUN` bodies are analyzed through a conservative safe-subset gate before any host Bash process is started. The gate is allowlist-oriented: simple modeled package-manager/language-installer commands, modeled predicates, modeled `case "$(uname -m)"` probes, safe loops over known variables, and common Dockerfile heredoc bodies may pass through to the stubbed interpreter. Unsupported command-introducing shell syntax is review-only by default. This intentionally favors missing an automatic conversion over executing host commands or emitting false certainty.

After a `RUN` body passes the safe-subset gate, dock2flox writes it into a temporary Bash script that defines stubs for package managers and common installers. Bash may expand variables and evaluate supported `if`, `case`, and loop control flow, but package-manager and installer commands record argv; they do not install packages, download scripts, or mutate the analyzer host. If interpretation times out or hits an unmodelled predicate, dock2flox emits a review hook instead of raw-splitting inactive branches.

Safety comes first. Path-addressed command words are review-only unless dock2flox explicitly models them as safe stubs. Commands such as `/usr/bin/touch`, `/bin/sh`, `/usr/bin/env`, `./install.sh`, `../script`, and `scripts/install.sh` are not executed on the analyzer host. Command-position variable expansions such as `$CMD ...`, `${CMD} ...`, `env $CMD ...`, `sudo $CMD ...`, `command $CMD ...`, `builtin command $CMD ...`, and `xargs $CMD ...` are also review-only, because Dockerfile `ENV`/`ARG` expansion may resolve them to slash-addressed host commands after static scanning. The safe-subset gate also rejects any command word that is not in dock2flox's modeled stub allowlist. Bash builtins with host effects or interpreter-state effects, including `kill`, `printf`, `read`, `mapfile`, `declare`, `typeset`, `readonly`, `export`, `unset`, `cd`, `pushd`, `popd`, `shopt`, `set`, `enable`, `hash`, `trap`, `alias`, and `unalias`, are review-only unless dock2flox later adds an explicit non-mutating model for them. Wrapper commands such as `command`, `builtin command`, `sudo`, `doas`, `env`, and `xargs`; shell functions; subshells and brace groups; `time`, `!`, and `coproc`; non-modelled command substitutions; `eval`, `source`, and `exec`; redirections; and process substitutions are outside the interpreted safe subset. The generated manifest receives a `REVIEW[...]` note, and dock2flox skips active package extraction for that `RUN` rather than pretending the result is certain. Variables are still allowed as arguments to modeled safe commands, such as `apt-get install -y $PKGS` or `npm install -g $TOOLS`. Flox tool wrappers that are explicitly modeled, such as `./mvnw` and `./gradlew`, are stubbed and recorded as lifecycle intent; the wrapper script itself is never executed. Existing path/wrapper/function guards remain inside the interpreter as defense-in-depth, but the safe-subset gate decides whether Bash may run at all.

Dockerfile `ENV` values are exported into later interpreted `RUN` bodies, matching Docker's behavior for cases such as `ENV PKGS="curl jq"` followed by `RUN apt-get install -y $PKGS`. Obvious non-terminating loops such as `while true; do ...`, `while :; do ...`, `until false; do ...`, and `for (( ; ; ))` are rejected before Bash is invoked and receive `REVIEW[run-timeout]`.

This improves cases such as:

```dockerfile
RUN pkgs="curl git"; if [ "$INSTALL_EXTRA" = "true" ]; then apt-get install -y $pkgs; fi
RUN for tool in yarn pnpm; do corepack enable "$tool"; done
RUN echo "apt-get install fake"; apt-get install -y ca-certificates
RUN case "$(uname -m)" in x86_64) apt-get install -y curl ;; aarch64) apt-get install -y git ;; esac
RUN <<EOF
apt-get install -y wget
EOF
```


## OCI Runtime Semantics

Dockerfiles include both environment requirements and OCI image/runtime packaging details. dock2flox now preserves common OCI semantics instead of silently dropping them:

- `WORKDIR` becomes `DOCK2FLOX_CONTAINER_WORKDIR` and, for common project-root paths such as `/app`, maps activation to `$FLOX_ENV_PROJECT`.
- `ENTRYPOINT` and `CMD` become metadata and a generated `[services].app.command` so the original runtime intent is visible and runnable after review.
- `EXPOSE`, `USER`, `VOLUME`, `HEALTHCHECK`, `STOPSIGNAL`, and `SHELL` become `DOCK2FLOX_*` metadata and review comments.
- `COPY` and `ADD` become review comments. The comments call out non-portable cases such as `--from=builder`, `--chown`, `--chmod`, and remote `ADD` URLs.

These translations are intentionally conservative. They preserve the runtime contract and convert the pieces Flox can use directly, but they do not claim to rebuild an OCI filesystem layer-for-layer.


## Language Ecosystem Lifecycle Support

dock2flox now treats common project-level package manager commands as
lifecycle intent instead of generic `# RUN:` comments. It installs the
relevant Flox toolchain/package-manager packages from
`data/language_ecosystems.map` and emits guarded hooks for dependency syncs:

- Node: `npm ci`, `npm install`, `yarn install`, `pnpm install`, and gated
  `npm/yarn/pnpm run ...` script commands.
- Ruby: `gem install bundler`, `bundle install`, `bundle update`, and gated
  `bundle exec ...` commands.
- PHP: `composer install`, `composer update`, and gated Composer script/autoload
  commands.
- Java: Maven and Gradle commands, including `./mvnw` and `./gradlew`, mapped
  to Flox-provided tools with review notes for wrapper-specific behavior.
- Rust and Go: `cargo fetch`, gated Cargo build/test/check/install commands,
  `go mod download`, and gated Go build/test/install/generate commands.

Dependency synchronization hooks run only when the expected project manifest is
present (`package.json`, `Gemfile`, `composer.json`, `pom.xml`, `Cargo.toml`,
`go.mod`, etc.). Build/test/script commands are preserved behind
`DOCK2FLOX_RUN_BUILD_STEPS=1` so activation does not unexpectedly perform heavy
build work. Direct dependency mutation commands such as `yarn add` and `pnpm add`
are preserved behind `DOCK2FLOX_SYNC_DIRECT_DEPS=1` and receive review notes.

## Package Mapping Strategy

dock2flox uses a 3-layer resolution strategy:

1. **Static tables** (`data/apt_to_nixpkgs.map`, `data/apk_to_nixpkgs.map`) — ~100 known apt/apk-to-nixpkgs mappings
2. **Heuristics** — strips `-dev` suffixes, `lib` prefixes, handles `python3-*` namespacing, version-suffixed packages
3. **Conflict rules** (`data/package_conflicts.map`) — automatically set Flox `priority` when known packages expose the same files
4. **Validation** (`--validate`) — live `flox search` calls to verify unmapped/heuristic packages

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


## Test Modes

The default test suite is the bounded production-regression mode:

```bash
tests/run_tests.sh
```

It runs a compact release section that covers the original brief gaps, host-mutation safety class, platform/ENV/SHELL/predicate regressions, Compose/OCI/package/language review behavior, and idempotent writes without accumulating many interpreter subprocesses in one harness process. Use slow mode to exercise timeout/process-cleanup coverage:

```bash
tests/run_tests.sh --slow
# or
DOCK2FLOX_TEST_SLOW=1 tests/run_tests.sh
```

Set `DOCK2FLOX_TEST_TIMING=1` to print per-test timings. Timed-out fixture renders include the fixture command in stderr. The Python harness uses an outer `timeout --kill-after` around each converter render; dock2flox also uses a short interpreter timeout in test mode. Parallel prewarming is disabled by default for deterministic local and CI runs; the larger section tests remain available through `tests/run_tests_split.py --section <core|shell|gaps|broad|idempotency>`. Production `RUN` interpretation remains configurable through `DOCK2FLOX_RUN_TIMEOUT`.

## Project Structure

```
bin/dock2flox              # Master entrypoint
lib/
  core.sh                  # Shared utilities, logging, temp files
  parser_dockerfile.sh     # Dockerfile parser
  run_shell_interpreter.sh  # Stubbed Bash interpreter for RUN bodies
  parser_compose.sh        # Compose parser wrapper/service handling
  parser_compose.py        # Structured YAML-aware Compose parser
  mapper_packages.sh       # apt/apk -> nixpkgs translation
  mapper_base_images.sh    # FROM image -> package mapping
  emitter_toml.sh          # IR -> manifest.toml generation
  validator.sh             # flox search validation
data/
  apt_to_nixpkgs.map       # Static apt package mappings
  apk_to_nixpkgs.map       # Static apk package mappings
  base_images.map          # Base image -> package mappings
  corepack_tools.map       # corepack-enabled tools -> Flox packages
  language_ecosystems.map  # language toolchain/package-manager mappings
  package_conflicts.map    # known file conflicts -> priority settings
  skip_patterns.list       # Patterns to ignore
tests/
  run_tests.sh             # Test runner
  fixtures/                # Test Dockerfiles and Compose files
```

## Running Tests

```bash
tests/run_tests.sh
```


### Package-source and mapping confidence

This bundle now treats bounded package coverage as a first-class migration
concern instead of hiding it behind best-effort mappings. Static map hits are
emitted as installable packages. Speculative distro-package heuristics are
emitted with `LOW` confidence and top-level `REVIEW[package-map]` comments.
Unmapped packages stay visible as commented `[install]` candidates with a
`flox search` hint.

The parser also records external package sources that can explain why a
Docker build succeeds when a public Flox catalog lookup might not: PPAs,
`sources.list.d` entries, apt keys/keyrings, local or remote `.deb`/`.rpm`
artifacts, apk repositories, yum/dnf repositories, pip indexes/VCS URLs, and
npm registries. These become `REVIEW[package-source]` comments near the top
of the generated manifest.

Use `--validate` when `flox` is available to upgrade non-EXACT candidates via
`flox search`, then promote durable mappings into `data/*.map` files.

## Limitations

- **RUN interpretation**: Bash-backed analysis improves quoting, variables, loops, heredocs, command substitutions, common OS probes, and conditionals, but it is intentionally stubbed and does not reproduce every side effect of a container shell. Dynamic package lists produced by downloaded scripts, generated files, or network calls may still need review. Architecture probes default to `DOCK2FLOX_RUN_ARCH=x86_64` unless overridden.
- **Compose orchestration**: Compose YAML is parsed structurally when PyYAML is available, including anchors/merge keys, but Flox does not recreate Docker Compose orchestration. Networks, volumes, secrets/configs, healthchecks, profiles, and service ordering are preserved as metadata and review notes.
- **Package coverage**: The static mapping tables cover ~100 common packages. Uncommon packages will be marked UNMAPPED.
- **Language package coverage**: Project-level lifecycle commands for Python, Node, Ruby, PHP, Java, Rust, and Go are converted to tool installs plus guarded hooks. Ecosystem internals are still delegated to their lockfiles/package managers, and ad-hoc direct dependency mutations are marked for review.
- **devcontainer.json**: Not yet implemented.
- **Version mapping**: Some version formats may not translate perfectly to Flox version constraints.

## Contributing

To add package mappings, edit the tab-separated files in `data/`:

```
# Format: distro_name<TAB>nixpkgs_path<TAB>optional_notes
my-package	nixpkgs-equivalent	any notes here
```

Then run `tests/run_tests.sh` to verify nothing breaks.

## Test harness determinism

The regression suite bounds every dry-run conversion so parser regressions fail
cleanly rather than hanging the suite:

```sh
DOCK2FLOX_TEST_TIMEOUT=30s DOCK2FLOX_RUN_TIMEOUT=1s tests/run_tests.sh
```

`DOCK2FLOX_RUN_TIMEOUT` controls the per-`RUN` Bash interpreter timeout. Normal
conversions default to `5s`; the test suite defaults it to `1s` because fixtures
should interpret quickly.

## Production correctness policy

`dock2flox` is intentionally conservative when Docker/Compose semantics cannot
be mapped safely to Flox:

- `FROM --platform=...` drives the architecture model used for common probes such
  as `uname -m`.
- Unknown shell predicates do **not** select a concrete branch. The converter
  emits `REVIEW[run-predicate]` and skips branch-specific package extraction for
  that `RUN`.
- Docker `SHELL` is honored for active extraction. Bash-only syntax under
  `/bin/sh -c` is preserved for review instead of being parsed with Bash.
- OCI and Compose runtime semantics that Flox cannot reproduce directly are
  preserved as metadata and `REVIEW[...]` comments rather than silently dropped
  or over-promised.
- Re-running the converter in default write mode is idempotent when the generated
  manifest is unchanged. Differing existing manifests still require `--force` or
  interactive confirmation.

This means the generated manifest prefers a safe review point over an incorrect
active package or hook.

## Production readiness hardening

The analyzer is conservative by design. Dockerfile `ENV` values are carried into later interpreted `RUN` bodies, concrete `FROM --platform=` values drive architecture probe modelling, and unresolved platform expressions such as `$TARGETPLATFORM` fail closed with `REVIEW[run-platform]` instead of silently defaulting to `x86_64`.

The test harness is bounded and deterministic: each fixture render runs in its own process group, timed-out renders kill child and grandchild processes, and stderr includes the failing command. `tests/run_tests.sh` is the release gate.
