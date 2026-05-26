#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import run_tests as t  # noqa: E402


def core() -> None:
    print("Dockerfile / Compose core tests:")
    t.run_expected("Python API (basic)", "Dockerfile.python-api", "python-api.toml")
    t.run_expected("Go (multi-stage + ARG)", "Dockerfile.multistage")
    t.smoke("Compose advanced: YAML merge resolved", "docker-compose.advanced.yml", r'DOCK2FLOX_COMPOSE_API_ENV_FEATURE_FLAG = "true"')
    t.smoke("Compose advanced: secrets review", "docker-compose.advanced.yml", r'REVIEW\[compose-secrets\]')
    t.smoke("Compose advanced: topology review", "docker-compose.advanced.yml", r'REVIEW\[compose-topology\]')


def shell_safety() -> None:
    print("Shell interpreter and safety tests:")
    t.smoke("shell interpreter expands package vars", "Dockerfile.shell-interpreter", r'curl\.pkg-path = "curl"')
    t.smoke("shell interpreter loop detects yarn", "Dockerfile.shell-interpreter", r'yarn-berry\.pkg-path = "yarn-berry"')
    t.absent("sh SHELL rejects bash-array curl", "Dockerfile.shell-sh-semantics", r'curl\.pkg-path = "curl"')
    t.smoke("bash SHELL accepts bash array curl", "Dockerfile.shell-bash-semantics", r'curl\.pkg-path = "curl"')
    t.combined_host_safety("host-mutating command class is review-only", "Dockerfile.host-safety-combined")
    t.smoke("normal modeled install still works", "Dockerfile.normal-install", r'curl\.pkg-path = "curl"')
    t.smoke("uname/heredoc/modelled tests work", "Dockerfile.shell-interpreter-advanced", r'curl\.pkg-path = "curl"')
    t.smoke("heredoc RUN body is interpreted", "Dockerfile.shell-interpreter-advanced", r'wget\.pkg-path = "wget"')
    t.smoke("platform arm64 uses arm branch", "Dockerfile.platform-arm64", r'curl\.pkg-path = "curl"')
    t.smoke("ENV package list reaches RUN curl", "Dockerfile.env-run", r'curl\.pkg-path = "curl"')
    t.smoke("ENV package list reaches RUN jq", "Dockerfile.env-run", r'jq\.pkg-path = "jq"')
    t.smoke("platform variable emits review", "Dockerfile.platform-var", r'REVIEW\[run-platform\]')
    t.absent("unknown predicate skips then branch", "Dockerfile.unknown-predicate", r'jq\.pkg-path = "jq"')
    t.absent("unknown predicate skips else branch", "Dockerfile.unknown-predicate", r'curl\.pkg-path = "curl"')
    t.smoke("obvious infinite loop rejected statically", "Dockerfile.run-timeout", r'REVIEW\[run-timeout\]')


def gaps() -> None:
    print("Brief gap closure tests:")
    t.smoke("npm global stays as hook", "Dockerfile.gaps", r'npm install -g corepack')
    t.smoke("POETRY_HOME becomes FLOX_ENV", "Dockerfile.gaps", r'export POETRY_HOME="\$FLOX_ENV"')
    t.absent("POETRY_HOME not literal /usr/local", "Dockerfile.gaps", r'POETRY_HOME = "/usr/local"')
    t.smoke("corepack enable yarn -> yarn-berry", "Dockerfile.gaps", r'yarn-berry\.pkg-path = "yarn-berry"')
    t.absent("corepack enable yarn not generic hook", "Dockerfile.gaps", r'# RUN: corepack enable yarn')
    t.smoke("requirements hook is active", "Dockerfile.gaps", r'uv pip install --quiet -r "requirements\.txt"')
    t.smoke("pyproject hook uses uv sync", "Dockerfile.gaps", r'uv sync --quiet')
    t.smoke("multi-installer detects poetry", "Dockerfile.gaps", r'poetry\.pkg-path = "poetry"')
    t.smoke("multi-installer detects rustup", "Dockerfile.gaps", r'rustup\.pkg-path = "rustc"')
    t.smoke("multi-installer detects pnpm", "Dockerfile.gaps", r'pnpm\.pkg-path = "nodePackages\.pnpm"')


def broad_semantics() -> None:
    print("OCI, package coverage, and language ecosystem tests:")
    t.smoke("OCI: WORKDIR metadata", "Dockerfile.oci-semantics", r'DOCK2FLOX_CONTAINER_WORKDIR = "/app"')
    t.smoke("OCI: ENTRYPOINT/CMD service", "Dockerfile.oci-semantics", r'uvicorn main:app --host 0\.0\.0\.0 --port 8080')
    t.smoke("OCI: COPY --from review", "Dockerfile.oci-semantics", r'Review: build-stage artifacts must be rebuilt or supplied outside Flox\.')
    t.smoke("package coverage: apt PPA review", "Dockerfile.package-coverage", r'REVIEW\[package-source\]')
    t.smoke("package coverage: version preserved", "Dockerfile.package-coverage", r'python312\.version = "3\.12\.2-1"')
    t.absent("package coverage: deb path not install entry", "Dockerfile.package-coverage", r'tool_deb\.pkg-path')
    t.smoke("language: npm ci hook", "Dockerfile.language-ecosystems", r'npm ci --omit=dev')
    t.smoke("language: yarn install hook", "Dockerfile.language-ecosystems", r'yarn install --immutable')
    t.smoke("language: pnpm install hook", "Dockerfile.language-ecosystems", r'pnpm install --frozen-lockfile')
    t.smoke("language: lifecycle review comments", "Dockerfile.language-ecosystems", r'REVIEW\[language-lifecycle\]')


def idempotency() -> None:
    print("Idempotency tests:")
    t.idempotency("identical default write is no-op", "Dockerfile.idempotency-fast")


def slow() -> None:
    print("Slow timeout/process-cleanup tests:")
    t.SLOW = True
    t.slow_timeout_fixture("dynamic timeout fixture is bounded", "Dockerfile.dynamic-timeout")


def release() -> None:
    print("Release production-regression tests:")
    # Original brief gap closure.
    gaps()
    # Combined safety and semantic regression fixture keeps the default suite
    # short enough to run reliably in constrained CI while still covering the
    # production blockers directly.
    host_paths = [
        Path("/tmp/d2f_absolute_touch"),
        Path("/tmp/d2f_envpath_touch"),
        Path("/tmp/d2f_argpath_touch"),
        Path("/tmp/d2f_command_touch"),
        Path("/tmp/d2f_builtin_command_touch"),
        Path("/tmp/d2f_xargs_touch"),
        Path("/tmp/d2f_fn_touch"),
        Path("/tmp/d2f_fn_env_touch"),
        Path("/tmp/d2f_time_touch"),
        Path("/tmp/d2f_bang_touch"),
        Path("/tmp/d2f_coproc_touch"),
        Path("/tmp/d2f_brace_touch"),
    ]
    for path in host_paths:
        path.unlink(missing_ok=True)
    actual = t.render(t.FIXTURES / "Dockerfile.production-regression")
    touched = [str(path) for path in host_paths if path.exists()]
    ok = not touched
    t.report("no host mutation from paths/wrappers/functions", ok, f"touched={touched}" if touched else "")
    for path in host_paths:
        path.unlink(missing_ok=True)
    t.kill_builtin_no_side_effect("kill builtin cannot affect host process")
    checks = [
        ("ENV PKGS expands to curl", r'curl\.pkg-path = "curl"'),
        ("ENV PKGS expands to jq", r'jq\.pkg-path = "jq"'),
        ("ENV conditional emits ca-certificates", r'cacert\.pkg-path = "cacert"'),
        ("arm64 uname branch emits wget", r'wget\.pkg-path = "wget"'),
        ("amd64-only branch skipped", r'make\.pkg-path = "gnumake"', False),
        ("path commands reviewed", r'REVIEW\[run-path\]'),
        ("functions reviewed", r'REVIEW\[run-function\]'),
        ("unsupported control reviewed", r'REVIEW\[run-unsupported\]'),
        ("unknown predicate reviewed", r'REVIEW\[run-predicate\]'),
        ("/bin/sh bash-array reviewed", r'REVIEW\[run-shell\]'),
    ]
    for item in checks:
        if len(item) == 3 and item[2] is False:
            t.report(item[0], re.search(item[1], actual) is None)
        else:
            t.report(item[0], re.search(item[1], actual) is not None)
    t.smoke("unresolved platform emits review", "Dockerfile.platform-var", r'REVIEW\[run-platform\]')
    t.smoke("Compose advanced topology review", "docker-compose.advanced.yml", r'REVIEW\[compose-topology\]')
    t.smoke("OCI COPY --from review", "Dockerfile.oci-semantics", r'Review: build-stage artifacts must be rebuilt or supplied outside Flox\.')
    t.smoke("package source review", "Dockerfile.package-coverage", r'REVIEW\[package-source\]')
    # Broader language/idempotency coverage remains available through
    # --section broad and --section idempotency; keep default release bounded.


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Run dock2flox test sections")
    parser.add_argument("--section", required=True, choices=["release", "core", "shell", "gaps", "broad", "idempotency", "slow"])
    args = parser.parse_args(argv)
    if "DOCK2FLOX_RUN_TIMEOUT" not in os.environ:
        t.RUN_TIMEOUT = "0.2s"
    print(f"dock2flox test section: {args.section}")
    print("================================")
    {
        "release": release,
        "core": core,
        "shell": shell_safety,
        "gaps": gaps,
        "broad": broad_semantics,
        "idempotency": idempotency,
        "slow": slow,
    }[args.section]()
    print("\n====================")
    print(f"Results: {t.GREEN}{t.PASS} passed{t.NC}, {t.RED}{t.FAIL} failed{t.NC}, {t.SKIP} skipped")
    return 1 if t.FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
