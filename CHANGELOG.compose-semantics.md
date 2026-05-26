# Compose semantics pass

This pass replaces the line-oriented Compose parser with a structured YAML-aware
parser that emits the existing dock2flox IR.

## Added

- `lib/parser_compose.py`, a Python/PyYAML-backed Compose parser.
- YAML merge/anchor support via `yaml.SafeLoader`.
- Service-scoped metadata variables for images, builds, commands, entrypoints,
  environment, env files, ports, expose, volumes, secrets, configs, depends_on,
  healthchecks, networks, profiles, labels, extra_hosts, and common runtime
  fields.
- Review markers for Compose topology that Flox cannot reproduce directly:
  networking, volumes, secrets/configs, build settings, healthchecks,
  profiles, and orchestration dependencies.
- A conservative Bash fallback that emits review markers when structured YAML
  parsing is unavailable.
- Regression fixture `tests/fixtures/docker-compose.advanced.yml`.

## Notes

The parser preserves Compose intent for review and activation metadata; it does
not claim to recreate Docker Compose orchestration or container networking.
