# OCI semantics preservation pass

This pass addresses the second reliability concern from the audit: important OCI/container semantics were previously skipped or left as vague comments.

## Added

- `WORKDIR` metadata and best-effort activation directory mapping.
- `ENTRYPOINT` and `CMD` metadata plus a generated `app` service command.
- `EXPOSE` metadata via `DOCK2FLOX_EXPOSED_PORTS`.
- `USER`, `VOLUME`, `HEALTHCHECK`, `STOPSIGNAL`, and `SHELL` metadata via `DOCK2FLOX_*` vars.
- Review hook comments for `COPY` and `ADD`, including `--from`, `--chown`, `--chmod`, and remote `ADD` caveats.
- Regression fixture and tests for OCI semantic preservation.

## Still conservative

Flox environments are not OCI image layers. This pass preserves and translates runtime intent, but it does not reproduce container-only filesystem ownership, image layers, or port publication automatically.
