# Package coverage and source-review pass

This pass addresses the bounded package-coverage concern without pretending
that every distro/private package has a direct Flox equivalent.

## Added

- Top-level `REVIEW[package-map]` comments for LOW-confidence heuristic mappings and UNMAPPED packages.
- Top-level `REVIEW[package-source]` comments for PPAs, apt source lists, apt keys/keyrings, local/remote `.deb` artifacts, apk repositories, yum/dnf repositories, RPM imports/artifacts, pip private indexes/VCS URLs, and npm registry configuration.
- Version preservation for apt/yum/dnf package pins such as `python3.12=3.12.2-1`.
- Interpreter stubs for `add-apt-repository`, `apt-key`, `dpkg`, `gpg`, `yum-config-manager`, `rpm`, `tee`, and `echo` so package-source intent is captured during RUN analysis.
- Regression fixture `Dockerfile.package-coverage` covering external sources, low-confidence heuristics, unmapped packages, pinned packages, and private registries.

## Changed

- Distro package heuristics now emit LOW confidence unless they resolve through a static map. This keeps the manifest useful while forcing review of speculative package names.
- `pip install` parsing from interpreted RUN events now preserves hyphenated package names and skips private/VCS source URLs instead of mangling them into package names.
- Global npm parsing now skips `--registry` values so registry URLs do not become fake package names.

## Validation

- `tests/run_tests.sh`: 55 passed, 0 failed, 0 skipped.
- All generated fixture manifests parse with Python `tomllib`.
