import 'package:cuberun/src/launcher.dart';
import 'package:test/test.dart';

/// AC7 / E6 — exit faithfulness: child killed by signal n => launcher
/// exits 128 + n; ordinary codes pass through; dart reports signal
/// deaths as negative exit codes.
void main() {
  test('signal deaths map to 128+n', () {
    expect(mapChildExit(-1), 129); // SIGHUP
    expect(mapChildExit(-2), 130); // SIGINT (Ctrl-C surfaces as 130)
    expect(mapChildExit(-9), 137); // SIGKILL
    expect(mapChildExit(-15), 143); // SIGTERM — the PoC's hard-coded case
    expect(mapChildExit(-11), 139); // SIGSEGV
  });

  test('ordinary exit codes pass through', () {
    expect(mapChildExit(0), 0);
    expect(mapChildExit(1), 1);
    expect(mapChildExit(42), 42);
    expect(mapChildExit(126), 126);
  });
}
