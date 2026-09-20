import 'dart:io';

import 'package:cuberun/cuberun.dart';

/// Entry point: exits with [runCli]'s code.
Future<void> main(List<String> args) async {
  exit(await runCli(args));
}
