# cuberun — justfile (dart is expected on PATH)

default:
    @just --list

# Format the whole tree (self-healing pre-commit style).
format:
    dart format .

# Gate: format must already be clean (CI parity).
format-check:
    dart format --set-exit-if-changed .

analyze:
    dart analyze --fatal-infos

# Unit + integration-filesystem + REG suites (no kernel sandbox needed).
test:
    dart pub get
    dart test --exclude-tags integration

# Full E2E: probe battery + tool-compat matrices + harness suites.
# Needs a host where sandbox-exec can apply profiles (bare metal / CI).
integration:
    dart pub get
    dart test --tags integration

build:
    dart pub get
    dart compile exe bin/cuberun.dart -o build/cuberun-macos-arm64

# Everything CI runs, in order.
ci: format-check analyze test
