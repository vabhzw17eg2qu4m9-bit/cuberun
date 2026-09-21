/// cube-sandbox — kernel-confined launcher for AI harnesses (pi / omp / fa):
/// wraps a harness's whole process tree in a macOS sandbox-exec Layer-0
/// profile resolved from a strict yaml manifest.
library;

export 'src/exceptions.dart';
export 'src/harness_manifest.dart';
export 'src/launcher.dart';
export 'src/paths.dart';
export 'src/preflight.dart';
export 'src/probe.dart';
export 'src/presets.dart';
export 'src/resolver.dart';
export 'src/runtime.dart';
export 'src/sbpl.dart';
export 'src/service_grants.dart';
export 'src/stage.dart';
export 'src/tool_catalog.dart';
export 'src/cli.dart' show kCubeSandboxVersion, runCli;
