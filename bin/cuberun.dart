import 'dart:io';

import 'package:cuberun/cuberun.dart';

Future<void> main(List<String> args) async {
  exit(await runCli(args));
}
