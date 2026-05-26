#!/usr/bin/env python3
"""Structured Docker Compose parser for dock2flox.

The Bash tool keeps IR generation and TOML emission in shell. This helper is
limited to YAML-aware Compose parsing and emits the same unit-separator IR
records that lib/core.sh uses.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import Any, Iterable

IR_DELIM = "\x1f"


def _ir_encode(value: Any) -> str:
    text = "" if value is None else str(value)
    text = text.replace("\\", "\\\\")
    text = text.replace("\n", "\\n")
    return text


def emit(kind: str, *fields: Any) -> None:
    encoded = [kind]
    encoded.extend(_ir_encode(field) for field in fields)
    sys.stdout.write(IR_DELIM.join(encoded) + "\n")


def ir_var(name: str, value: Any, line: int = 0) -> None:
    emit("VAR", name, value, line)


def ir_hook(order: str, line_text: str, line: int = 0) -> None:
    emit("HOOK", order, line_text, line)


def ir_service(name: str, command: str, line: int = 0) -> None:
    emit("SERVICE", sanitize_service_name(name), command, line)


def ir_skip(instruction: str, reason: str, line: int = 0) -> None:
    emit("SKIP", instruction, reason, line)


def ir_review(category: str, detail: str, line: int = 0) -> None:
    emit("REVIEW", category, detail, line)


def ir_service_image(service: str, image: str, line: int = 0) -> None:
    emit("SERVICE_IMAGE", sanitize_service_name(service), image, service, line)


def ir_service_cmd(service: str, command: str, line: int = 0) -> None:
    emit("SERVICE_CMD", sanitize_service_name(service), command, line)


def sanitize_env_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_]", "_", value.upper())
    value = re.sub(r"_+", "_", value).strip("_")
    if not value:
        value = "VALUE"
    if value[0].isdigit():
        value = "_" + value
    return value


def sanitize_service_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_]", "_", value)
    value = re.sub(r"_+", "_", value).strip("_")
    if not value:
        value = "service"
    if value[0].isdigit():
        value = "svc_" + value
    return value


def shell_quote(value: str) -> str:
    return shlex.quote(value)


def compact(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def load_compose(path: Path) -> dict[str, Any]:
    try:
        import yaml  # type: ignore
    except Exception as exc:  # pragma: no cover - exercised by environments without PyYAML
        raise RuntimeError(
            "PyYAML is required for structured Compose parsing. Install python3-yaml or PyYAML."
        ) from exc

    class ComposeLoader(yaml.SafeLoader):
        pass

    # Docker Compose accepts !reset and !override tags in newer specs. Treat
    # unknown tagged values as their underlying YAML value so the parser can
    # still preserve review metadata instead of failing hard.
    def construct_unknown(loader: yaml.SafeLoader, tag_suffix: str, node: yaml.Node) -> Any:
        if isinstance(node, yaml.MappingNode):
            return loader.construct_mapping(node)
        if isinstance(node, yaml.SequenceNode):
            return loader.construct_sequence(node)
        return loader.construct_scalar(node)

    ComposeLoader.add_multi_constructor("!", construct_unknown)

    text = path.read_text(encoding="utf-8")
    loaded = yaml.load(text, Loader=ComposeLoader)
    if loaded is None:
        return {}
    if not isinstance(loaded, dict):
        raise ValueError("Compose file root must be a mapping")
    return loaded


def find_line(path: Path, needles: Iterable[str]) -> int:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except Exception:
        return 0
    for index, line in enumerate(lines, start=1):
        stripped = line.strip()
        for needle in needles:
            if needle and needle in stripped:
                return index
    return 0


def normalize_command(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return " ".join(shell_quote(str(item)) for item in value)
    return compact(value)


def parse_environment(value: Any) -> dict[str, str]:
    env: dict[str, str] = {}
    if value is None:
        return env
    if isinstance(value, dict):
        for key, val in value.items():
            if val is None:
                env[str(key)] = ""
            elif isinstance(val, bool):
                env[str(key)] = "true" if val else "false"
            else:
                env[str(key)] = str(val)
        return env
    if isinstance(value, list):
        for item in value:
            if isinstance(item, str):
                if "=" in item:
                    key, val = item.split("=", 1)
                    env[key] = val
                else:
                    env[item] = ""
            elif isinstance(item, dict):
                env.update(parse_environment(item))
        return env
    return env


def parse_env_files(value: Any) -> list[str]:
    result: list[str] = []
    for item in as_list(value):
        if isinstance(item, str):
            result.append(item)
        elif isinstance(item, dict):
            path = item.get("path") or item.get("file")
            if path:
                result.append(str(path))
    return result


def split_port_short(value: str) -> tuple[str, str, str]:
    proto = "tcp"
    if "/" in value:
        value, proto = value.rsplit("/", 1)
    parts = value.split(":")
    if len(parts) == 1:
        return "", parts[0], proto
    if len(parts) == 2:
        return parts[0], parts[1], proto
    # host_ip:published:target, including IPv6-ish strings as a best effort
    return parts[-2], parts[-1], proto


def parse_ports(value: Any) -> list[dict[str, str]]:
    ports: list[dict[str, str]] = []
    for item in as_list(value):
        if isinstance(item, str):
            published, target, proto = split_port_short(item)
            ports.append({"published": published, "target": target, "protocol": proto, "raw": item})
        elif isinstance(item, dict):
            target = item.get("target", "")
            published = item.get("published", "")
            proto = item.get("protocol", "tcp")
            raw = compact(item)
            ports.append({"published": str(published), "target": str(target), "protocol": str(proto), "raw": raw})
        else:
            ports.append({"published": "", "target": str(item), "protocol": "tcp", "raw": str(item)})
    return ports


def summarize_mount(item: Any) -> dict[str, str]:
    if isinstance(item, str):
        parts = item.split(":")
        source = parts[0] if parts else ""
        target = parts[1] if len(parts) > 1 else ""
        mode = ":".join(parts[2:]) if len(parts) > 2 else ""
        return {"source": source, "target": target, "mode": mode, "type": "short", "raw": item}
    if isinstance(item, dict):
        return {
            "source": str(item.get("source") or item.get("src") or ""),
            "target": str(item.get("target") or item.get("dst") or item.get("destination") or ""),
            "mode": str(item.get("mode") or ""),
            "type": str(item.get("type") or "volume"),
            "raw": compact(item),
        }
    return {"source": "", "target": "", "mode": "", "type": "unknown", "raw": str(item)}


def emit_prefixed_var(service: str, suffix: str, value: Any, line: int = 0) -> None:
    ir_var(f"DOCK2FLOX_COMPOSE_{sanitize_env_name(service)}_{sanitize_env_name(suffix)}", value, line)


def emit_service_environment(service: str, env: dict[str, str], line: int) -> None:
    for key, value in sorted(env.items()):
        safe_key = sanitize_env_name(key)
        emit_prefixed_var(service, f"ENV_{safe_key}", value, line)
        # Preserve legacy behavior for simple Compose files by emitting the raw
        # environment name too. If multiple services define the same key, the
        # emitter's sort/dedupe keeps one value and the service-scoped copy
        # remains authoritative for review.
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
            ir_var(key, value, line)


def emit_healthcheck(service: str, value: Any, line: int) -> None:
    if value is None:
        return
    if isinstance(value, dict):
        test = value.get("test")
        command = normalize_command(test)
        if command:
            emit_prefixed_var(service, "HEALTHCHECK_TEST", command, line)
        for key in ("interval", "timeout", "retries", "start_period", "start_interval", "disable"):
            if key in value:
                emit_prefixed_var(service, f"HEALTHCHECK_{key}", value[key], line)
        ir_review("compose-healthcheck", f"service {service}: healthcheck preserved as metadata; Flox does not enforce Compose healthcheck orchestration", line)
    else:
        emit_prefixed_var(service, "HEALTHCHECK", compact(value), line)
        ir_review("compose-healthcheck", f"service {service}: healthcheck preserved as metadata", line)


def emit_depends_on(service: str, value: Any, line: int) -> None:
    if value is None:
        return
    deps: list[str] = []
    if isinstance(value, list):
        deps = [str(item) for item in value]
    elif isinstance(value, dict):
        deps = [str(key) for key in value.keys()]
        for dep, spec in value.items():
            if isinstance(spec, dict) and spec:
                emit_prefixed_var(service, f"DEPENDS_ON_{dep}", compact(spec), line)
    else:
        deps = [str(value)]
    if deps:
        emit_prefixed_var(service, "DEPENDS_ON", " ".join(deps), line)
        ir_review("compose-orchestration", f"service {service}: depends_on preserved; startup ordering/readiness must be handled outside Flox", line)


def emit_build(service: str, value: Any, line: int) -> None:
    if value is None:
        return
    if isinstance(value, str):
        emit_prefixed_var(service, "BUILD_CONTEXT", value, line)
        ir_review("compose-build", f"service {service}: build context {value} preserved; run the build or supply artifacts outside Flox", line)
        return
    if isinstance(value, dict):
        for key in ("context", "dockerfile", "target", "platform", "pull", "no_cache"):
            if key in value:
                emit_prefixed_var(service, f"BUILD_{key}", value[key], line)
        for key in ("args", "additional_contexts", "cache_from", "cache_to", "secrets", "ssh"):
            if key in value:
                emit_prefixed_var(service, f"BUILD_{key}", compact(value[key]), line)
        ir_review("compose-build", f"service {service}: Compose build configuration preserved as metadata; image build is not executed by dock2flox", line)


def emit_service(service: str, spec: dict[str, Any], path: Path) -> None:
    line = find_line(path, [f"{service}:"])
    safe_service = sanitize_service_name(service)

    emit_prefixed_var(service, "PRESENT", "1", line)

    image = spec.get("image")
    if image:
        image_s = str(image)
        ir_service_image(service, image_s, line)
        emit_prefixed_var(service, "IMAGE", image_s, line)

    if "build" in spec:
        emit_build(service, spec.get("build"), line)

    command = normalize_command(spec.get("command"))
    entrypoint = normalize_command(spec.get("entrypoint"))
    if command:
        ir_service_cmd(service, command, line)
        emit_prefixed_var(service, "COMMAND", command, line)
    if entrypoint:
        emit_prefixed_var(service, "ENTRYPOINT", entrypoint, line)
        if command:
            ir_service_cmd(service, f"{entrypoint} {command}", line)
        else:
            ir_service_cmd(service, entrypoint, line)

    env = parse_environment(spec.get("environment"))
    emit_service_environment(service, env, line)

    env_files = parse_env_files(spec.get("env_file"))
    if env_files:
        emit_prefixed_var(service, "ENV_FILES", " ".join(env_files), line)
        ir_review("compose-env", f"service {service}: env_file entries preserved; load these files before activating if needed: {', '.join(env_files)}", line)

    ports = parse_ports(spec.get("ports"))
    if ports:
        targets = []
        published = []
        raw = []
        for port in ports:
            if port.get("target"):
                targets.append(port["target"])
            if port.get("published"):
                published.append(port["published"])
            raw.append(port.get("raw", ""))
        if targets:
            emit_prefixed_var(service, "PORTS", " ".join(targets), line)
            ir_var(f"{sanitize_env_name(service)}_PORT", targets[0], line)
        if published:
            emit_prefixed_var(service, "PUBLISHED_PORTS", " ".join(published), line)
        emit_prefixed_var(service, "PORT_SPECS", " | ".join(raw), line)
        ir_review("compose-networking", f"service {service}: port mappings preserved; expose/connect ports explicitly outside Compose", line)

    expose = as_list(spec.get("expose"))
    if expose:
        emit_prefixed_var(service, "EXPOSE", " ".join(str(item) for item in expose), line)
        ir_review("compose-networking", f"service {service}: expose entries are container-network-only hints", line)

    volumes = [summarize_mount(item) for item in as_list(spec.get("volumes"))]
    if volumes:
        emit_prefixed_var(service, "VOLUMES", " | ".join(mount["raw"] for mount in volumes), line)
        for index, mount in enumerate(volumes, start=1):
            if mount.get("source"):
                emit_prefixed_var(service, f"VOLUME_{index}_SOURCE", mount["source"], line)
            if mount.get("target"):
                emit_prefixed_var(service, f"VOLUME_{index}_TARGET", mount["target"], line)
            if mount.get("type"):
                emit_prefixed_var(service, f"VOLUME_{index}_TYPE", mount["type"], line)
        ir_review("compose-volumes", f"service {service}: volume mounts preserved; bind/named volume semantics require manual setup", line)

    for key in ("secrets", "configs"):
        entries = as_list(spec.get(key))
        if entries:
            emit_prefixed_var(service, key.upper(), " | ".join(compact(item) for item in entries), line)
            ir_review("compose-secrets", f"service {service}: {key} preserved as metadata; Flox manifest does not materialize Compose {key}", line)

    emit_depends_on(service, spec.get("depends_on"), line)
    emit_healthcheck(service, spec.get("healthcheck"), line)

    networks = spec.get("networks")
    if networks:
        emit_prefixed_var(service, "NETWORKS", compact(networks), line)
        ir_review("compose-networking", f"service {service}: custom networks/aliases preserved; recreate network topology outside Flox if needed", line)

    profiles = as_list(spec.get("profiles"))
    if profiles:
        emit_prefixed_var(service, "PROFILES", " ".join(str(item) for item in profiles), line)
        ir_review("compose-profiles", f"service {service}: profiles preserved; select services intentionally when activating", line)

    for key in ("container_name", "hostname", "restart", "platform", "user", "working_dir", "privileged", "init", "tty", "stdin_open"):
        if key in spec:
            emit_prefixed_var(service, key, spec[key], line)
            ir_review("compose-runtime", f"service {service}: {key} preserved as runtime metadata", line)

    labels = spec.get("labels")
    if labels:
        emit_prefixed_var(service, "LABELS", compact(labels), line)

    extra_hosts = spec.get("extra_hosts")
    if extra_hosts:
        emit_prefixed_var(service, "EXTRA_HOSTS", compact(extra_hosts), line)
        ir_review("compose-networking", f"service {service}: extra_hosts preserved as metadata", line)

    # Warn for fields we preserve only generically. Keep this explicit so users
    # can inspect full Compose semantics instead of assuming equivalence.
    known = {
        "image", "build", "command", "entrypoint", "environment", "env_file", "ports", "expose",
        "volumes", "secrets", "configs", "depends_on", "healthcheck", "networks", "profiles",
        "container_name", "hostname", "restart", "platform", "user", "working_dir", "privileged",
        "init", "tty", "stdin_open", "labels", "extra_hosts",
    }
    for key in sorted(set(spec.keys()) - known):
        emit_prefixed_var(service, f"FIELD_{key}", compact(spec[key]), line)
        ir_review("compose-unsupported", f"service {service}: field {key} preserved generically; verify semantics manually", line)

    if not image and "build" not in spec:
        ir_review("compose-service", f"service {service}: no image/build field found; only metadata could be preserved", line)


def emit_top_level(compose: dict[str, Any], path: Path) -> None:
    line = 0
    for key in ("name", "version"):
        if key in compose:
            ir_var(f"DOCK2FLOX_COMPOSE_{sanitize_env_name(key)}", compose[key], line)

    for key in ("volumes", "networks", "secrets", "configs"):
        value = compose.get(key)
        if value:
            ir_var(f"DOCK2FLOX_COMPOSE_TOPLEVEL_{sanitize_env_name(key)}", compact(value), line)
            ir_review("compose-topology", f"top-level {key} preserved; create equivalent resources outside Flox if needed", line)

    for key in sorted(set(compose.keys()) - {"name", "version", "services", "volumes", "networks", "secrets", "configs"}):
        ir_var(f"DOCK2FLOX_COMPOSE_TOPLEVEL_{sanitize_env_name(key)}", compact(compose[key]), line)
        ir_review("compose-unsupported", f"top-level field {key} preserved generically", line)


def parse(path: Path) -> None:
    compose = load_compose(path)
    emit_top_level(compose, path)

    services = compose.get("services") or {}
    if not isinstance(services, dict):
        ir_review("compose-error", "services must be a mapping; no Compose services parsed", 0)
        return

    for service, spec in services.items():
        if spec is None:
            spec = {}
        if not isinstance(spec, dict):
            ir_review("compose-error", f"service {service}: expected mapping, got {type(spec).__name__}", find_line(path, [f"{service}:"]))
            continue
        emit_service(str(service), spec, path)

    ir_review("compose-parser", f"parsed {len(services)} service(s) with structured YAML semantics", 0)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: parser_compose.py <compose-file>\n")
        return 2
    path = Path(argv[1])
    try:
        parse(path)
    except Exception as exc:
        sys.stderr.write(f"dock2flox compose parser error: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
