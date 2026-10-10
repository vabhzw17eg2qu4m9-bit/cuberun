import 'package:cube_sandbox/src/launcher.dart';
import 'package:test/test.dart';

/// Issue #113 — the launch-shape policy matrix, all six rows. A tty
/// caller execs into the confined harness (zero resident launcher — the
/// #81 raw-mode EIO hazard is unconstructible); headless callers keep
/// #53 spawn-and-exit byte-identical; explicit `--wait` forces the
/// blocking parent shape everywhere. `--spawn-exit` survives for CLI
/// compatibility only: it can no longer change the shape.
void main() {
  test('tty + default: exec — cube-sandbox replaces itself (#113)', () {
    expect(
      launchShape(
        waitFlag: false,
        spawnExitFlag: false,
        stdinHasTerminal: true,
      ),
      LaunchShape.exec,
    );
  });

  test('tty + --spawn-exit: exec (nothing resident to opt out of)', () {
    expect(
      launchShape(waitFlag: false, spawnExitFlag: true, stdinHasTerminal: true),
      LaunchShape.exec,
    );
  });

  test('tty + --wait: blocking parent shape (#81 verbatim)', () {
    expect(
      launchShape(waitFlag: true, spawnExitFlag: false, stdinHasTerminal: true),
      LaunchShape.wait,
    );
  });

  test('headless + default: spawn-and-exit (#53 invariant)', () {
    expect(
      launchShape(
        waitFlag: false,
        spawnExitFlag: false,
        stdinHasTerminal: false,
      ),
      LaunchShape.spawnExit,
    );
  });

  test('headless + --spawn-exit: spawn-and-exit (same as default)', () {
    expect(
      launchShape(
        waitFlag: false,
        spawnExitFlag: true,
        stdinHasTerminal: false,
      ),
      LaunchShape.spawnExit,
    );
  });

  test('headless + --wait: blocking parent shape', () {
    expect(
      launchShape(
        waitFlag: true,
        spawnExitFlag: false,
        stdinHasTerminal: false,
      ),
      LaunchShape.wait,
    );
  });
}
