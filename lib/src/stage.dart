/// ProfileStage: content-addressed staging of emitted profiles under
/// `<projDir>/.cuberun/cache/harness-<key10>.sb` — atomic rename, and
/// identical staged content is NEVER rewritten (mtime-stable, E7).
library;

import 'dart:io' as io;

/// Stages [text] as `<cacheDir>/harness-<key10>.sb` and returns the path.
///
/// Creates [cacheDir] (and its self-gitignoring `.gitignore`) as needed.
/// If the target exists with identical content the file is left untouched
/// (no rewrite => stable mtime); otherwise a `<name>.tmp.<pid>` sibling is
/// written and renamed over the target.
String stageProfile({
  required String cacheDir,
  required String text,
  required String key10,
  int? pid,
}) {
  final dir = io.Directory(cacheDir);
  dir.createSync(recursive: true);
  final gitignore = io.File('${dir.path}/.gitignore');
  if (!gitignore.existsSync()) {
    gitignore.writeAsStringSync('*\n!.gitignore\n');
  }
  final finalPath = '${dir.path}/harness-$key10.sb';
  final file = io.File(finalPath);
  if (file.existsSync() && file.readAsStringSync() == text) {
    return finalPath; // identical content — never rewritten (E7)
  }
  final tmpPath = '${dir.path}/harness-$key10.sb.tmp.${pid ?? io.pid}';
  io.File(tmpPath).writeAsStringSync(text, flush: true);
  io.File(tmpPath).renameSync(finalPath);
  return finalPath;
}

/// The per-project cache dir for staged profiles.
String projectCacheDir(String projDir) => '$projDir/.cuberun/cache';
