# Language ecosystem lifecycle support

This pass addresses the fourth reliability concern: project lifecycle support was uneven outside Python and simple Node/corepack cases.

## Added

- `data/language_ecosystems.map` for data-driven runtime/package-manager mappings.
- Node lifecycle extraction for `npm ci`, `npm install`, `npm run`, `yarn install`, `yarn run`, `pnpm install`, and `pnpm run`.
- Ruby/Bundler extraction for `gem install bundler`, `bundle install`, `bundle update`, and gated `bundle exec` commands.
- PHP/Composer extraction for `composer install`, `composer update`, `composer dump-autoload`, and `composer run-script`.
- Java lifecycle extraction for Maven and Gradle, including `./mvnw` and `./gradlew` wrappers.
- Rust lifecycle extraction for `cargo fetch`, `cargo build`, `cargo test`, `cargo check`, and `cargo install`.
- Go lifecycle extraction for `go mod download`, `go build`, `go test`, `go install`, and `go generate`.
- Cache hook inference for Yarn, pnpm, Bundler, Composer, Maven, and Gradle.
- Regression fixture `tests/fixtures/Dockerfile.language-ecosystems`.

## Behavior

- Dependency sync commands are emitted as active hooks guarded by project manifest files.
- Build/test/script commands are emitted behind `DOCK2FLOX_RUN_BUILD_STEPS=1` to avoid unexpectedly doing heavy work on activation.
- Direct dependency mutation commands are gated behind `DOCK2FLOX_SYNC_DIRECT_DEPS=1` and get `REVIEW[language-lifecycle]` comments.
- Wrapper commands (`./mvnw`, `./gradlew`) install Flox-provided tools and emit review comments for wrapper-specific behavior.
