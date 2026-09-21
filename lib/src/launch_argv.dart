/// Launch argv pass-through: the positional split is the contract —
/// cube-sandbox options precede the profile, everything after the first
/// positional is the harness's argv (issue #43).
library;

/// The `launch` argv partition: [args] is the option+profile region the
/// strict scanner sees; [tail] is everything after the profile — the
/// harness's argv, forwarded verbatim.
typedef LaunchSplit = ({List<String> args, List<String> tail});

/// Partitions `launch` argv into `[options…] <profile> [tail…]`: the
/// first positional is the profile and every token after it (flag-shaped
/// or not) belongs to the harness, verbatim and in order. A bare `--`
/// keeps its existing `-- <command…>` override role: the tail ends there
/// and the override region stays in [LaunchSplit.args] for the scanner.
LaunchSplit splitLaunchArgv(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--') return (args: args, tail: const <String>[]);
    // --file/--yaml consume a value token; any other flag stands alone.
    if (a == '--file' || a == '--yaml') i++;
    if (a.startsWith('--')) continue;
    final tail = args.sublist(i + 1);
    final dd = tail.indexOf('--');
    if (dd < 0) return (args: args.sublist(0, i + 1), tail: tail);
    return (
      args: [...args.sublist(0, i + 1), '--', ...tail.sublist(dd + 1)],
      tail: tail.sublist(0, dd),
    );
  }
  return (args: args, tail: const <String>[]);
}
