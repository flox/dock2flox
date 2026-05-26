# wrapper dispatch safety hardening

- Fixed a host-mutation class where wrapper/builtin commands could dispatch
  slash-addressed analyzer-host binaries after the static path-command scanner.
- `command /path`, `builtin command /path`, and `xargs /path` are now review-only.
- `command $CMD`, `builtin command $CMD`, and `xargs $CMD` are now review-only.
- Interpreter wrappers (`command`, `builtin command`, `sudo`, `doas`, `env`,
  `xargs`) now dispatch only to allowlisted dock2flox stubs and never execute
  arbitrary argv on the analyzer host.
- `sh -c`/`bash -c` wrappers are preserved as review metadata rather than evaled
  inside the analyzer.
- Added regression fixtures covering literal and variable wrapper dispatch, plus
  continued support for variable arguments to modeled package-manager commands.
