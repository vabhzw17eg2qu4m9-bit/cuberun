import 'dart:io';

import 'package:cube_sandbox/cube_sandbox.dart';

/// Entry point: exits with [runCli]'s code.
Future<void> main(List<String> args) async {
  exit(await runCli(args));
}
