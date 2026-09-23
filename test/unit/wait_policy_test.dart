import 'package:cube_sandbox/src/launcher.dart';
import 'package:test/test.dart';

/// Issue #81 C1(b) — the launch-mode policy: a TUI caller (stdin is a
/// terminal) needs the launcher to HOLD the foreground for the child's
/// lifetime; a headless caller keeps #53 spawn-and-exit byte-identical.
/// Explicit flags always win; `--spawn-exit` exists precisely to force
/// the legacy shape from a terminal.
void main() {
  test('explicit --wait waits, even headless', () {
    expect(
      shouldWait(waitFlag: true, spawnExitFlag: false, stdinHasTerminal: false),
      isTrue,
    );
  });

  test('explicit --spawn-exit forces spawn-and-exit, even on a tty', () {
    expect(
      shouldWait(waitFlag: false, spawnExitFlag: true, stdinHasTerminal: true),
      isFalse,
    );
  });

  test('tty default holds the foreground (wait)', () {
    expect(
      shouldWait(waitFlag: false, spawnExitFlag: false, stdinHasTerminal: true),
      isTrue,
    );
  });

  test('headless default stays spawn-and-exit (#53 invariant)', () {
    expect(
      shouldWait(
        waitFlag: false,
        spawnExitFlag: false,
        stdinHasTerminal: false,
      ),
      isFalse,
    );
  });
}
