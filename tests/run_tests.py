#!/usr/bin/env python3
from __future__ import annotations

import argparse
import difflib
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
DOCK2FLOX = ROOT_DIR / "bin" / "dock2flox"
FIXTURES = SCRIPT_DIR / "fixtures"
EXPECTED = FIXTURES / "expected"

GREEN = "\033[0;32m" if sys.stdout.isatty() else ""
RED = "\033[0;31m" if sys.stdout.isatty() else ""
NC = "\033[0m" if sys.stdout.isatty() else ""

PASS = 0
FAIL = 0
SKIP = 0
CACHE: dict[tuple[str, tuple[str, ...]], str] = {}
STDERR_CACHE: dict[tuple[str, tuple[str, ...]], str] = {}
ERROR_CACHE: dict[tuple[str, tuple[str, ...]], str] = {}

RUN_TIMEOUT = os.environ.get("DOCK2FLOX_RUN_TIMEOUT", "0.2s")
RENDER_TIMEOUT = float(os.environ.get("DOCK2FLOX_TEST_TIMEOUT_SECONDS", "10"))
TIMING = os.environ.get("DOCK2FLOX_TEST_TIMING") == "1"
SLOW = False


def _killpg(proc: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()


def run_cmd(cmd: list[str], timeout_s: float = RENDER_TIMEOUT, cwd: Path | None = None) -> tuple[int, str, str]:
    if os.environ.get("DOCK2FLOX_TEST_TRACE") == "1":
        print(f"[trace] start {' '.join(cmd)}", file=sys.stderr, flush=True)
    env = os.environ.copy()
    env.setdefault("DOCK2FLOX_SERVICES", "container")
    env.setdefault("DOCK2FLOX_RUN_TIMEOUT", RUN_TIMEOUT)

    # Prefer GNU timeout for fixture-level bounding. The converter itself also
    # uses timeout for interpreted RUN bodies, so this outer layer catches any
    # harness or converter stall and prints the exact command under test. Python
    # keeps a second small timeout around the timeout process as a last resort.
    timeout_cmd = ["timeout", "--kill-after=2s", f"{timeout_s}s", *cmd] if shutil.which("timeout") else cmd
    try:
        completed = subprocess.run(
            timeout_cmd,
            cwd=str(cwd or ROOT_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=timeout_s + 5,
        )
        rc = completed.returncode
        out_b = completed.stdout
        err_b = completed.stderr
        if rc == 124:
            err_b += f"[dock2flox-test] timed out after {timeout_s}s running: {' '.join(cmd)}\n".encode()
    except subprocess.TimeoutExpired as exc:
        rc = 124
        out_b = exc.stdout or b""
        err_b = exc.stderr or b""
        err_b += f"[dock2flox-test] python timeout after {timeout_s + 5}s running: {' '.join(cmd)}\n".encode()
    except Exception as exc:
        rc = 125
        out_b = b""
        err_b = f"[dock2flox-test] failed to run {' '.join(cmd)}: {exc}\n".encode()

    out = out_b.decode(errors="replace")
    err = err_b.decode(errors="replace")
    if os.environ.get("DOCK2FLOX_TEST_TRACE") == "1":
        print(f"[trace] done rc={rc} {' '.join(cmd)}", file=sys.stderr, flush=True)
    return rc, out, err


def _render_uncached(path: Path, extra_args: tuple[str, ...] = ()) -> str:
    key = (str(path), extra_args)
    cmd = [str(DOCK2FLOX), "--dry-run", *extra_args, str(path)]
    rc, out, err = run_cmd(cmd)
    STDERR_CACHE[key] = err
    if rc != 0:
        msg = f"render failed rc={rc} fixture={path.name}: {' '.join(cmd)}\n{err[:2000]}"
        ERROR_CACHE[key] = msg
        raise RuntimeError(msg)
    CACHE[key] = out
    ERROR_CACHE.pop(key, None)
    return out


def render(path: Path, extra_args: tuple[str, ...] = ()) -> str:
    key = (str(path), extra_args)
    if key in ERROR_CACHE:
        raise RuntimeError(ERROR_CACHE[key])
    if key in CACHE:
        return CACHE[key]
    return _render_uncached(path, extra_args)


def prewarm(fixtures: list[str]) -> None:
    # Pre-render expensive, side-effect-free fixtures in parallel. Side-effect
    # regression fixtures are intentionally excluded so those tests still prove
    # the host filesystem is not mutated at assertion time.
    workers = int(os.environ.get("DOCK2FLOX_TEST_PREWARM_WORKERS", "3"))
    workers = max(1, min(workers, 8))
    if workers == 1:
        for fixture in fixtures:
            try:
                render(FIXTURES / fixture)
            except Exception:
                pass
        return
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futs = {pool.submit(_render_uncached, FIXTURES / fixture): fixture for fixture in fixtures}
        for fut in as_completed(futs):
            try:
                fut.result()
            except Exception:
                # Individual tests surface cached errors with full context.
                pass

def _timing_detail(detail: str, elapsed: float | None) -> str:
    if TIMING and elapsed is not None:
        suffix = f"{elapsed:.3f}s"
        return f"{detail} [{suffix}]" if detail else f"[{suffix}]"
    return detail


def report(name: str, ok: bool, detail: str = "", elapsed: float | None = None) -> None:
    global PASS, FAIL
    detail = _timing_detail(detail, elapsed)
    print(f"  {name:<40}", end="")
    if ok:
        print(f"{GREEN}PASS{NC}" + (f" {detail}" if detail else ""))
        PASS += 1
    else:
        print(f"{RED}FAIL{NC}" + (f" ({detail})" if detail else ""))
        FAIL += 1


def skip(name: str, reason: str) -> None:
    global SKIP
    print(f"  {name:<40}SKIP {reason}")
    SKIP += 1


def run_expected(name: str, fixture: str, expected: str | None = None, extra_args: tuple[str, ...] = ()) -> None:
    start = time.perf_counter()
    try:
        actual = render(FIXTURES / fixture, extra_args)
        elapsed = time.perf_counter() - start
        if expected:
            exp = (EXPECTED / expected).read_text()
            if actual == exp:
                report(name, True, elapsed=elapsed)
            else:
                diff = "".join(difflib.unified_diff(exp.splitlines(True), actual.splitlines(True), fromfile=expected, tofile="actual", n=3))
                report(name, False, "output differs", elapsed=elapsed)
                print(diff[:2000])
        else:
            report(name, "[install]" in actual, "(produces [install] section)" if "[install]" in actual else "no [install]", elapsed=elapsed)
    except Exception as exc:
        report(name, False, str(exc).splitlines()[0], elapsed=time.perf_counter() - start)


def smoke(name: str, fixture: str, pattern: str) -> None:
    start = time.perf_counter()
    try:
        actual = render(FIXTURES / fixture)
        found = re.search(pattern, actual) is not None
        report(name, found, f"pattern not found: {pattern}" if not found else "", elapsed=time.perf_counter() - start)
    except Exception as exc:
        report(name, False, str(exc).splitlines()[0], elapsed=time.perf_counter() - start)


def absent(name: str, fixture: str, pattern: str) -> None:
    start = time.perf_counter()
    try:
        actual = render(FIXTURES / fixture)
        found = re.search(pattern, actual) is not None
        report(name, not found, f"forbidden pattern found: {pattern}" if found else "", elapsed=time.perf_counter() - start)
    except Exception as exc:
        report(name, False, str(exc).splitlines()[0], elapsed=time.perf_counter() - start)


def no_side_effect(name: str, fixture: str) -> None:
    start = time.perf_counter()
    touched = ROOT_DIR / "host_was_touched"
    try:
        if touched.exists():
            touched.unlink()
        render(FIXTURES / fixture)
        report(name, not touched.exists(), "RUN redirection wrote to analyzer cwd" if touched.exists() else "", elapsed=time.perf_counter() - start)
    except Exception as exc:
        report(name, False, str(exc).splitlines()[0], elapsed=time.perf_counter() - start)
    finally:
        if touched.exists():
            touched.unlink()


def absolute_path_no_side_effect(name: str, fixture: str, host_path: Path) -> None:
    start = time.perf_counter()
    try:
        if host_path.exists():
            host_path.unlink()
        actual = render(FIXTURES / fixture)
        ok = (not host_path.exists()) and "REVIEW[run-path]" in actual
        detail = "" if ok else f"host_exists={host_path.exists()} review={'REVIEW[run-path]' in actual}"
        report(name, ok, detail, elapsed=time.perf_counter() - start)
    except Exception as exc:
        report(name, False, str(exc).splitlines()[0], elapsed=time.perf_counter() - start)
    finally:
        if host_path.exists():
            host_path.unlink()


def function_no_side_effect(name: str, fixture: str, host_path: Path) -> None:
    start = time.perf_counter()
    try:
        if host_path.exists():
            host_path.unlink()
        actual = render(FIXTURES / fixture)
        ok = (not host_path.exists()) and "REVIEW[run-function]" in actual
        detail = "" if ok else f"host_exists={host_path.exists()} review={'REVIEW[run-function]' in actual}"
        report(name, ok, detail, elapsed=time.perf_counter() - start)
    except Exception as exc:
        report(name, False, str(exc).splitlines()[0], elapsed=time.perf_counter() - start)
    finally:
        if host_path.exists():
            host_path.unlink()


def combined_host_safety(name: str, fixture: str) -> None:
    start = time.perf_counter()
    host_paths = [
        Path("/tmp/d2f_absolute_touch"),
        Path("/tmp/d2f_envpath_touch"),
        Path("/tmp/d2f_argpath_touch"),
        Path("/tmp/d2f_env_wrapper_touch"),
        Path("/tmp/d2f_sudo_wrapper_touch"),
        Path("/tmp/d2f_command_touch"),
        Path("/tmp/d2f_builtin_command_touch"),
        Path("/tmp/d2f_xargs_touch"),
        Path("/tmp/d2f_command_var_touch"),
        Path("/tmp/d2f_builtin_command_var_touch"),
        Path("/tmp/d2f_xargs_var_touch"),
        Path("/tmp/d2f_fn_touch"),
        Path("/tmp/d2f_fn_env_touch"),
        Path("/tmp/d2f_fn_kw_touch"),
        Path("/tmp/d2f_time_touch"),
        Path("/tmp/d2f_bang_touch"),
        Path("/tmp/d2f_coproc_touch"),
        Path("/tmp/d2f_brace_touch"),
    ]
    try:
        for path in host_paths:
            path.unlink(missing_ok=True)
        actual = render(FIXTURES / fixture)
        touched = [str(path) for path in host_paths if path.exists()]
        ok = not touched and "REVIEW[run-path]" in actual and "REVIEW[run-function]" in actual and "REVIEW[run-unsupported]" in actual and 'curl.pkg-path = "curl"' in actual
        detail = "" if ok else f"touched={touched} path_review={'REVIEW[run-path]' in actual} fn_review={'REVIEW[run-function]' in actual} unsupported_review={'REVIEW[run-unsupported]' in actual} curl={'curl.pkg-path = \"curl\"' in actual}"
        report(name, ok, detail, elapsed=time.perf_counter() - start)
    except Exception as exc:
        report(name, False, str(exc).splitlines()[0], elapsed=time.perf_counter() - start)
    finally:
        for path in host_paths:
            path.unlink(missing_ok=True)


def local_script_no_side_effect(name: str, fixture: str) -> None:
    start = time.perf_counter()
    marker = ROOT_DIR / "local_script_was_touched"
    script = FIXTURES / "install.sh"
    try:
        marker.unlink(missing_ok=True)
        script.write_text(f"#!/usr/bin/env sh\ntouch {marker}\n")
        script.chmod(0o755)
        actual = render(FIXTURES / fixture)
        ok = (not marker.exists()) and "REVIEW[run-path]" in actual
        detail = "" if ok else f"marker_exists={marker.exists()} review={'REVIEW[run-path]' in actual}"
        report(name, ok, detail, elapsed=time.perf_counter() - start)
    except Exception as exc:
        report(name, False, str(exc).splitlines()[0], elapsed=time.perf_counter() - start)
    finally:
        marker.unlink(missing_ok=True)
        script.unlink(missing_ok=True)


def slow_timeout_fixture(name: str, fixture: str) -> None:
    if not SLOW:
        skip(name, "slow timeout mode disabled; run tests/run_tests.sh --slow")
        return
    smoke(name, fixture, r'REVIEW\[run-dynamic\]|cacert\.pkg-path = "cacert"')


def kill_builtin_no_side_effect(name: str) -> None:
    start = time.perf_counter()
    proc = subprocess.Popen(["sleep", "30"])
    tmp = Path(tempfile.mkdtemp(prefix="dock2flox-kill-regression."))
    try:
        dockerfile = tmp / "Dockerfile.kill-builtin"
        dockerfile.write_text(f"FROM debian:bookworm\nRUN kill -TERM {proc.pid}\n")
        rc, out, err = run_cmd([str(DOCK2FLOX), "--dry-run", str(dockerfile)])
        alive = proc.poll() is None
        ok = rc == 0 and alive and "REVIEW[run-unsupported]" in out
        detail = "" if ok else f"rc={rc} alive={alive} review={'REVIEW[run-unsupported]' in out} stderr={err[:200]!r}"
        report(name, ok, detail, elapsed=time.perf_counter() - start)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait(timeout=2)
        shutil.rmtree(tmp, ignore_errors=True)


def idempotency(name: str, fixture: str) -> None:
    start = time.perf_counter()
    out_dir = Path(tempfile.mkdtemp(prefix="dock2flox-idempotent."))
    try:
        rc1, _out1, err1 = run_cmd([str(DOCK2FLOX), "-o", str(out_dir), str(FIXTURES / fixture)])
        rc2, _out2, err2 = run_cmd([str(DOCK2FLOX), "-o", str(out_dir), str(FIXTURES / fixture)])
        ok = rc1 == 0 and rc2 == 0 and "Unchanged:" in err2 and not re.search(r"syntax error|error token|warning:", err2, re.I)
        detail = ""
        if not ok:
            detail = f"rc1={rc1} rc2={rc2} stderr2={err2[:300]!r}"
        report(name, ok, detail, elapsed=time.perf_counter() - start)
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    global SLOW, RUN_TIMEOUT, RENDER_TIMEOUT
    parser = argparse.ArgumentParser(description="Run dock2flox regression tests")
    parser.add_argument("--slow", action="store_true", help="run intentional timeout/process-cleanup fixtures")
    args = parser.parse_args(argv)
    SLOW = args.slow or os.environ.get("DOCK2FLOX_TEST_SLOW") == "1"
    if SLOW and "DOCK2FLOX_RUN_TIMEOUT" not in os.environ:
        RUN_TIMEOUT = "0.2s"
    elif "DOCK2FLOX_RUN_TIMEOUT" not in os.environ:
        RUN_TIMEOUT = "0.2s"
    print("dock2flox test suite")
    print("====================")
    print(f"mode: {'slow' if SLOW else 'fast'}; run-timeout={RUN_TIMEOUT}; fixture-timeout={RENDER_TIMEOUT}s\n")

    if SLOW:
        print("Slow timeout/process-cleanup tests:")
        slow_timeout_fixture("dynamic timeout fixture is bounded", "Dockerfile.dynamic-timeout")
        print("\n====================")
        print(f"Results: {GREEN}{PASS} passed{NC}, {RED}{FAIL} failed{NC}, {SKIP} skipped")
        return 1 if FAIL else 0

    if os.environ.get("DOCK2FLOX_TEST_PREWARM") == "1":
        prewarm([
            "Dockerfile.python-api",
            "Dockerfile.node",
            "Dockerfile.multistage",
            "docker-compose.yml",
            "docker-compose.advanced.yml",
            "Dockerfile.shell-interpreter",
            "Dockerfile.shell-sh-semantics",
            "Dockerfile.shell-bash-semantics",
            "Dockerfile.safety",
            "Dockerfile.active-installers",
            "Dockerfile.shell-interpreter-advanced",
            "Dockerfile.platform-arm64",
            "Dockerfile.env-run",
            "Dockerfile.platform-var",
            "Dockerfile.unknown-predicate",
            "Dockerfile.run-timeout",
            "Dockerfile.gaps",
            "Dockerfile.oci-semantics",
            "Dockerfile.package-coverage",
            "Dockerfile.language-ecosystems",
        ])

    print("Dockerfile parsing:")
    run_expected("Python API (basic)", "Dockerfile.python-api", "python-api.toml")
    run_expected("Node.js (multi-stage)", "Dockerfile.node", "node.toml")
    run_expected("Go (multi-stage + ARG)", "Dockerfile.multistage")

    print("\nPackage mapping smoke tests:")
    smoke("apt curl -> curl", "Dockerfile.python-api", r'curl\.pkg-path = "curl"')
    smoke("apt libpq-dev -> postgresql", "Dockerfile.python-api", r'postgresql\.pkg-path = "postgresql"')
    smoke("apt build-essential -> gcc", "Dockerfile.python-api", r'gcc\.pkg-path = "gcc"')
    smoke("FROM python:3.11 -> python311", "Dockerfile.python-api", r'python311')
    smoke("apk ca-certificates -> cacert", "Dockerfile.multistage", r'cacert\.pkg-path = "cacert"')
    smoke("ENV APP_PORT -> [vars]", "Dockerfile.multistage", r'APP_PORT = "8080"')

    print("\nCompose parsing:")
    smoke("Compose: detects postgres vars", "docker-compose.yml", r'PGHOST')
    smoke("Compose: detects redis vars", "docker-compose.yml", r'REDIS')
    smoke("Compose: captures env vars", "docker-compose.yml", r'APP_ENV')
    smoke("Compose advanced: YAML merge resolved", "docker-compose.advanced.yml", r'DOCK2FLOX_COMPOSE_API_ENV_FEATURE_FLAG = "true"')
    smoke("Compose advanced: build metadata", "docker-compose.advanced.yml", r'DOCK2FLOX_COMPOSE_API_BUILD_DOCKERFILE = "Dockerfile\.api"')
    smoke("Compose advanced: long ports", "docker-compose.advanced.yml", r'DOCK2FLOX_COMPOSE_API_PUBLISHED_PORTS = "18080"')
    smoke("Compose advanced: healthcheck preserved", "docker-compose.advanced.yml", r'DOCK2FLOX_COMPOSE_API_HEALTHCHECK_TEST = "CMD-SHELL')
    smoke("Compose advanced: secrets review", "docker-compose.advanced.yml", r'REVIEW\[compose-secrets\]')
    smoke("Compose advanced: topology review", "docker-compose.advanced.yml", r'REVIEW\[compose-topology\]')

    print("\nShell interpreter tests:")
    smoke("shell interpreter expands package vars", "Dockerfile.shell-interpreter", r'curl\.pkg-path = "curl"')
    smoke("shell interpreter preserves quoted separators", "Dockerfile.shell-interpreter", r'cacert\.pkg-path = "cacert"')
    smoke("shell interpreter loop detects yarn", "Dockerfile.shell-interpreter", r'yarn-berry\.pkg-path = "yarn-berry"')
    smoke("shell interpreter loop detects pnpm", "Dockerfile.shell-interpreter", r'pnpm\.pkg-path = "nodePackages\.pnpm"')
    absent("quoted installer text is not parsed", "Dockerfile.shell-interpreter", r'fakepkg')
    absent("sh SHELL rejects bash-array curl", "Dockerfile.shell-sh-semantics", r'curl\.pkg-path = "curl"')
    absent("sh SHELL rejects bash-array jq", "Dockerfile.shell-sh-semantics", r'jq\.pkg-path = "jq"')
    smoke("sh SHELL emits review", "Dockerfile.shell-sh-semantics", r'REVIEW\[run-shell\]')
    smoke("bash SHELL accepts bash array curl", "Dockerfile.shell-bash-semantics", r'curl\.pkg-path = "curl"')
    smoke("bash SHELL accepts bash array jq", "Dockerfile.shell-bash-semantics", r'jq\.pkg-path = "jq"')
    smoke("command -v models debian apt branch", "Dockerfile.safety", r'curl\.pkg-path = "curl"')
    absent("command -v avoids alpine branch", "Dockerfile.safety", r'cacert\.pkg-path = "cacert"')
    absent("quoted installer URL is inert", "Dockerfile.safety", r'rustup\.pkg-path = "rustc"')
    absent("eval string is not fallback-parsed", "Dockerfile.safety", r'curl_\.pkg-path')
    smoke("active curl installer detects rustup", "Dockerfile.active-installers", r'rustup\.pkg-path = "rustc"')
    smoke("active wget installer detects poetry", "Dockerfile.active-installers", r'poetry\.pkg-path = "poetry"')
    no_side_effect("redirection cannot write analyzer cwd", "Dockerfile.redirection")
    combined_host_safety("host-mutating command class is review-only", "Dockerfile.host-safety-combined")
    kill_builtin_no_side_effect("kill builtin cannot affect host process")
    smoke("normal modeled install still works", "Dockerfile.normal-install", r'curl\.pkg-path = "curl"')
    smoke("uname case uses active arch branch", "Dockerfile.shell-interpreter-advanced", r'curl\.pkg-path = "curl"')
    absent("uname case skips inactive arch branch", "Dockerfile.shell-interpreter-advanced", r'git\.pkg-path = "git"')
    smoke("heredoc RUN body is interpreted", "Dockerfile.shell-interpreter-advanced", r'wget\.pkg-path = "wget"')
    smoke("modelled bash file test works", "Dockerfile.shell-interpreter-advanced", r'cacert\.pkg-path = "cacert"')
    absent("uncertain predicate avoids text fallback", "Dockerfile.shell-interpreter-advanced", r'jq\.pkg-path = "jq"')
    smoke("platform arm64 uses arm branch", "Dockerfile.platform-arm64", r'curl\.pkg-path = "curl"')
    absent("platform arm64 skips amd64 branch", "Dockerfile.platform-arm64", r'jq\.pkg-path = "jq"')
    smoke("ENV package list reaches RUN curl", "Dockerfile.env-run", r'curl\.pkg-path = "curl"')
    smoke("ENV package list reaches RUN jq", "Dockerfile.env-run", r'jq\.pkg-path = "jq"')
    smoke("ENV conditional reaches RUN", "Dockerfile.env-run", r'cacert\.pkg-path = "cacert"')
    smoke("platform variable emits review", "Dockerfile.platform-var", r'REVIEW\[run-platform\]')
    absent("platform variable skips amd64 branch", "Dockerfile.platform-var", r'jq\.pkg-path = "jq"')
    absent("platform variable skips arm branch", "Dockerfile.platform-var", r'curl\.pkg-path = "curl"')
    absent("unknown predicate skips then branch", "Dockerfile.unknown-predicate", r'jq\.pkg-path = "jq"')
    absent("unknown predicate skips else branch", "Dockerfile.unknown-predicate", r'curl\.pkg-path = "curl"')
    smoke("unknown predicate emits review", "Dockerfile.unknown-predicate", r'REVIEW\[run-predicate\]')
    smoke("obvious infinite loop rejected statically", "Dockerfile.run-timeout", r'REVIEW\[run-timeout\]')
    smoke("static loop fixture continues to next RUN", "Dockerfile.run-timeout", r'cacert\.pkg-path = "cacert"')
    slow_timeout_fixture("dynamic timeout fixture is bounded", "Dockerfile.dynamic-timeout")

    print("\nGap closure tests:")
    smoke("npm global stays as hook", "Dockerfile.gaps", r'npm install -g corepack')
    smoke("POETRY_HOME becomes FLOX_ENV", "Dockerfile.gaps", r'export POETRY_HOME="\$FLOX_ENV"')
    absent("POETRY_HOME not literal /usr/local", "Dockerfile.gaps", r'POETRY_HOME = "/usr/local"')
    smoke("corepack enable yarn -> yarn-berry", "Dockerfile.gaps", r'yarn-berry\.pkg-path = "yarn-berry"')
    absent("corepack enable yarn not generic hook", "Dockerfile.gaps", r'# RUN: corepack enable yarn')
    smoke("requirements hook is active", "Dockerfile.gaps", r'uv pip install --quiet -r "requirements\.txt"')
    smoke("pyproject hook uses uv sync", "Dockerfile.gaps", r'uv sync --quiet')
    smoke("multi-installer detects poetry", "Dockerfile.gaps", r'poetry\.pkg-path = "poetry"')
    smoke("multi-installer detects rustup", "Dockerfile.gaps", r'rustup\.pkg-path = "rustc"')
    smoke("multi-installer detects pnpm", "Dockerfile.gaps", r'pnpm\.pkg-path = "nodePackages\.pnpm"')

    print("\nOCI semantics preservation tests:")
    smoke("OCI: WORKDIR metadata", "Dockerfile.oci-semantics", r'DOCK2FLOX_CONTAINER_WORKDIR = "/app"')
    smoke("OCI: EXPOSE metadata", "Dockerfile.oci-semantics", r'DOCK2FLOX_EXPOSED_PORTS = "8080 9090"')
    smoke("OCI: USER metadata", "Dockerfile.oci-semantics", r'DOCK2FLOX_CONTAINER_USER = "appuser"')
    smoke("OCI: VOLUME metadata", "Dockerfile.oci-semantics", r'DOCK2FLOX_CONTAINER_VOLUMES = "/data /cache"')
    smoke("OCI: HEALTHCHECK metadata", "Dockerfile.oci-semantics", r'DOCK2FLOX_HEALTHCHECK = "--interval=30s CMD curl -f http://localhost:8080/health \|\| exit 1"')
    smoke("OCI: ENTRYPOINT/CMD service", "Dockerfile.oci-semantics", r'uvicorn main:app --host 0\.0\.0\.0 --port 8080')
    smoke("OCI: COPY --from review", "Dockerfile.oci-semantics", r'Review: build-stage artifacts must be rebuilt or supplied outside Flox\.')
    smoke("OCI: remote ADD review", "Dockerfile.oci-semantics", r'Review: remote ADD should usually become an explicit fetch/checksum step\.')

    print("\nPackage coverage and source review tests:")
    smoke("package coverage: apt PPA review", "Dockerfile.package-coverage", r'REVIEW\[package-source\]')
    smoke("package coverage: version preserved", "Dockerfile.package-coverage", r'python312\.version = "3\.12\.2-1"')
    smoke("package coverage: low heuristic reviewed", "Dockerfile.package-coverage", r'REVIEW\[package-map\]')
    smoke("package coverage: external deb is not mapped as package", "Dockerfile.package-coverage", r'external package artifact: \./vendor/tool\.deb')
    absent("package coverage: deb path not install entry", "Dockerfile.package-coverage", r'tool_deb\.pkg-path')
    smoke("package coverage: pip private index review", "Dockerfile.package-coverage", r'pip source or external package input detected: --extra-index-url https://pypi\.example\.com/simple')
    smoke("package coverage: npm registry review", "Dockerfile.package-coverage", r'npm source or external package input detected: npm config set registry https://npm\.example\.com')

    print("\nLanguage ecosystem lifecycle tests:")
    smoke("language: npm ci hook", "Dockerfile.language-ecosystems", r'npm ci --omit=dev')
    smoke("language: yarn install hook", "Dockerfile.language-ecosystems", r'yarn install --immutable')
    smoke("language: pnpm install hook", "Dockerfile.language-ecosystems", r'pnpm install --frozen-lockfile')
    smoke("language: build steps gated", "Dockerfile.language-ecosystems", r'DOCK2FLOX_RUN_BUILD_STEPS')
    smoke("language: bundler install hook", "Dockerfile.language-ecosystems", r'bundle install --without development')
    smoke("language: composer install hook", "Dockerfile.language-ecosystems", r'composer install --no-dev --prefer-dist')
    smoke("language: maven wrapper converted", "Dockerfile.language-ecosystems", r'mvn -DskipTests package')
    smoke("language: gradle build hook", "Dockerfile.language-ecosystems", r'gradle build --no-daemon')
    smoke("language: cargo fetch hook", "Dockerfile.language-ecosystems", r'cargo fetch')
    smoke("language: go mod hook", "Dockerfile.language-ecosystems", r'go mod download')
    smoke("language: lifecycle review comments", "Dockerfile.language-ecosystems", r'REVIEW\[language-lifecycle\]')

    print("\nIdempotency tests:")
    idempotency("identical default write is no-op", "Dockerfile.idempotency-fast")

    print("\n====================")
    print(f"Results: {GREEN}{PASS} passed{NC}, {RED}{FAIL} failed{NC}, {SKIP} skipped")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
