#!/usr/bin/env python3
"""dock2flox devcontainer.json parser — emits IR records to stdout."""

import json
import re
import sys
from pathlib import Path

IR_DELIM = "\x1f"

SKIP_ENV = {"DEBIAN_FRONTEND", "APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE"}

# Extensions whose presence implies a project CLI tool dependency
EXTENSION_TOOL_HINTS = {
    "charliermarsh.ruff": "ruff",
    "ms-python.black-formatter": "black",
    "ms-python.mypy-type-checker": "mypy",
    "ms-python.pylint": "pylint",
    "dbaeumer.vscode-eslint": "eslint",
    "esbenp.prettier-vscode": "prettier",
}

DEV_SERVER_PATTERNS = [
    "npm run dev", "npm start", "yarn dev", "pnpm dev",
    "flask run", "uvicorn ", "gunicorn ", "rails server",
    "hugo server", "jekyll serve", "next dev", "vite",
]


def _ir_encode(value):
    s = str(value)
    s = s.replace("\\", "\\\\")
    s = s.replace("\t", "\\t")
    s = s.replace("\n", "\\n")
    s = s.replace("\r", "\\r")
    return s


def emit(kind, *fields):
    parts = [kind] + [_ir_encode(f) for f in fields]
    sys.stdout.write(IR_DELIM.join(parts) + "\n")


def ir_install(install_id, pkg_path, version="", pkg_group="", confidence="EXACT", line=0, notes=""):
    emit("INSTALL", install_id, pkg_path, version, pkg_group, confidence, line, notes)


def ir_var(name, value, line=0):
    emit("VAR", name, value, line)


def ir_hook(order, text, line=0):
    emit("HOOK", order, text, line)


def ir_review(category, detail, line=0):
    emit("REVIEW", category, detail, line)


def ir_service(name, command, line=0):
    emit("SERVICE", name, command, line)


# --- Path variable substitution ---

def substitute_paths(value):
    """Replace devcontainer path variables with Flox equivalents."""
    value = value.replace("${containerWorkspaceFolder}", "$FLOX_ENV_PROJECT")
    value = value.replace("${localWorkspaceFolder}", "$FLOX_ENV_PROJECT")
    value = value.replace("${containerWorkspaceFolderBasename}", "$(basename $FLOX_ENV_PROJECT)")
    value = value.replace("${localWorkspaceFolderBasename}", "$(basename $FLOX_ENV_PROJECT)")
    # ${localEnv:VAR:default} → ${VAR:-default}
    value = re.sub(r"\$\{localEnv:([^:}]+):([^}]+)\}", r"${\1:-\2}", value)
    # ${localEnv:VAR} → $VAR
    value = re.sub(r"\$\{localEnv:([^}]+)\}", r"$\1", value)
    # ${containerEnv:VAR:default} → ${VAR:-default}
    value = re.sub(r"\$\{containerEnv:([^:}]+):([^}]+)\}", r"${\1:-\2}", value)
    # ${containerEnv:VAR} → $VAR
    value = re.sub(r"\$\{containerEnv:([^}]+)\}", r"$\1", value)
    # /workspaces/<name> → $FLOX_ENV_PROJECT
    value = re.sub(r"/workspaces/[^/\"'\s]+", "$FLOX_ENV_PROJECT", value)
    value = re.sub(r"/workspace(?=[/\"'\s]|$)", "$FLOX_ENV_PROJECT", value)
    return value


# --- Feature mapping ---

def load_features_map():
    """Load the feature URI → package mapping table."""
    features_map = {}
    map_path = Path(__file__).parent.parent / "data" / "devcontainer_features.map"
    if not map_path.exists():
        return features_map
    for line in map_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 3:
            uri, pkg_path, version_key = parts[0], parts[1], parts[2]
            notes = parts[3] if len(parts) > 3 else ""
            features_map[uri] = (pkg_path, version_key, notes)
    return features_map


def emit_features(features):
    """Map devcontainer features to [install] entries."""
    features_map = load_features_map()

    for uri, options in features.items():
        if not isinstance(options, dict):
            options = {}

        # Strip version tag from URI: ghcr.io/.../node:1 → ghcr.io/.../node
        base_uri = re.sub(r":[^/]+$", "", uri)

        if base_uri in features_map:
            pkg_path, version_key, notes = features_map[base_uri]

            if pkg_path == "_conditional_":
                # Handle conditional features (e.g., common-utils with installZsh)
                for mapping in version_key.split(","):
                    opt_key, _, pkg = mapping.partition("=")
                    opt_key = opt_key.strip()
                    pkg = pkg.strip()
                    if options.get(opt_key, False) in (True, "true", "True"):
                        ir_install(pkg, pkg, "", "", "EXACT", 0, f"from devcontainer feature {uri}")
                continue

            # Extract version from feature options
            version = ""
            if version_key != "_" and version_key in options:
                version = str(options[version_key])

            install_id = pkg_path
            if version and pkg_path in ("nodejs", "jdk"):
                install_id = f"{pkg_path}_{version}" if version != "latest" else pkg_path

            ir_install(install_id, pkg_path if "_{}" not in pkg_path else pkg_path,
                       version, "", "EXACT", 0, f"from devcontainer feature {uri}")
        else:
            ir_review("devcontainer-feature",
                      f"Feature {uri} not in dock2flox feature mapping table; add to data/devcontainer_features.map or install manually")


def emit_container_env(env):
    """Map containerEnv to [vars]."""
    for name, value in env.items():
        if name in SKIP_ENV:
            continue
        ir_var(name, str(value))


def emit_remote_env(env):
    """Map remoteEnv to [hook] exports with path substitution."""
    for name, value in env.items():
        value = substitute_paths(str(value))
        ir_hook("050", f'export {name}="{value}"')


def normalize_command(cmd):
    """Normalize lifecycle command to a list of shell strings."""
    if isinstance(cmd, str):
        return [cmd]
    elif isinstance(cmd, list):
        return [" ".join(str(c) for c in cmd)]
    elif isinstance(cmd, dict):
        return [str(v) for v in cmd.values()]
    return []


def emit_lifecycle_commands(config):
    """Map lifecycle commands to hooks, services, or REVIEW markers."""
    # initializeCommand runs on HOST — always REVIEW
    init_cmd = config.get("initializeCommand")
    if init_cmd:
        for cmd in normalize_command(init_cmd):
            ir_review("devcontainer-host-command",
                      f"initializeCommand runs on the host, not in the container: {cmd}")

    # Lifecycle order: onCreate → updateContent → postCreate → postStart → postAttach
    lifecycle_hooks = [
        ("onCreateCommand", "060"),
        ("updateContentCommand", "070"),
        ("postCreateCommand", "080"),
        ("postStartCommand", "090"),
    ]

    for prop, order in lifecycle_hooks:
        cmd = config.get(prop)
        if not cmd:
            continue
        for shell_cmd in normalize_command(cmd):
            shell_cmd = substitute_paths(shell_cmd)
            ir_hook(order, shell_cmd)
            ir_review("devcontainer-lifecycle",
                      f"{prop}: {shell_cmd} — review whether this should run on every activation or be an explicit task")

    # postAttachCommand → service if it looks like a dev server, otherwise REVIEW
    attach_cmd = config.get("postAttachCommand")
    if attach_cmd:
        for shell_cmd in normalize_command(attach_cmd):
            shell_cmd = substitute_paths(shell_cmd)
            if any(p in shell_cmd for p in DEV_SERVER_PATTERNS):
                ir_service("web", shell_cmd)
            else:
                ir_hook("200", f"# postAttachCommand: {shell_cmd}")
                ir_review("devcontainer-lifecycle",
                          f"postAttachCommand: {shell_cmd} — consider making this a Flox service or explicit task")


def emit_forward_ports(ports):
    """Note forwarded ports as REVIEW metadata."""
    if not ports:
        return
    port_list = ", ".join(str(p) for p in ports)
    ir_review("devcontainer-ports",
              f"forwardPorts [{port_list}] noted; host processes do not need port forwarding. "
              f"Set PORT vars in [vars] or [services] only if the application reads them.")


def emit_customizations(customizations):
    """Skip editor config; note tool-implying extensions."""
    if not customizations:
        return

    vscode = customizations.get("vscode", {})
    extensions = vscode.get("extensions", [])

    hinted_tools = []
    for ext_id in extensions:
        ext_lower = ext_id.lower()
        for known_ext, tool in EXTENSION_TOOL_HINTS.items():
            if ext_lower == known_ext.lower():
                hinted_tools.append(f"{ext_id} implies {tool}")

    if hinted_tools:
        ir_review("devcontainer-extensions",
                  f"VSCode extensions suggest project tools: {'; '.join(hinted_tools)}. "
                  f"Declare these in [install] if project commands, CI, or hooks invoke them directly.")

    # Note that editor settings are intentionally not mapped
    settings = vscode.get("settings", {})
    if settings:
        ir_review("devcontainer-editor",
                  "VSCode settings preserved in devcontainer.json; editor preferences stay with the editor, not the Flox manifest.")


def emit_image_and_build(config):
    """Note image/build properties as REVIEW metadata."""
    image = config.get("image")
    if image:
        ir_review("devcontainer-image",
                  f"Base image {image} — consider mapping its runtime dependencies to [install] entries.")

    build = config.get("build")
    if build:
        if isinstance(build, str):
            # String form: "build": ".." means context="..", dockerfile="Dockerfile"
            context = build
            dockerfile = "Dockerfile"
        else:
            context = build.get("context", ".")
            dockerfile = build.get("dockerfile", "Dockerfile")
        # Emit metadata so the bash wrapper can chain to the Dockerfile parser
        ir_var("DOCK2FLOX_BUILD_CONTEXT", context)
        ir_var("DOCK2FLOX_BUILD_DOCKERFILE", dockerfile)


def emit_skipped_properties(config):
    """Note container-only mechanics that don't map to Flox."""
    skipped = []
    for key in ("containerUser", "remoteUser", "mounts", "workspaceMount",
                "workspaceFolder", "runArgs", "overrideCommand", "capAdd",
                "securityOpt", "hostRequirements"):
        if key in config:
            skipped.append(key)
    if skipped:
        ir_review("devcontainer-container-only",
                  f"Container-only properties skipped: {', '.join(skipped)}. "
                  f"These describe container runtime mechanics, not the development environment.")


# --- Main ---

def parse(path):
    text = path.read_text()
    # Strip JSON comments (// style) and trailing commas for compat with jsonc
    text = re.sub(r"//.*$", "", text, flags=re.MULTILINE)
    text = re.sub(r",\s*([}\]])", r"\1", text)
    config = json.loads(text)

    ir_review("devcontainer-parser",
              f"parsed devcontainer.json: {config.get('name', path.name)}")

    emit_features(config.get("features", {}))
    emit_container_env(config.get("containerEnv", {}))
    emit_remote_env(config.get("remoteEnv", {}))
    emit_lifecycle_commands(config)
    emit_forward_ports(config.get("forwardPorts", []))
    emit_customizations(config.get("customizations", {}))
    emit_image_and_build(config)
    emit_skipped_properties(config)


def main(argv):
    if len(argv) != 2:
        print(f"Usage: {argv[0]} <devcontainer.json>", file=sys.stderr)
        return 1

    path = Path(argv[1])
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        return 1

    try:
        parse(path)
        return 0
    except Exception as e:
        print(f"Error parsing {path}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
