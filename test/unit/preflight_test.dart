import 'dart:io' as io;

import 'package:cuberun/src/preflight.dart';
import 'package:test/test.dart';

/// AC5 — fail-closed preflight: every exit-126 branch driven through the
/// injected seams (runner / platform / which), plus the pure PATH lookup
/// `whichPathIn` against real temp-dir fixtures.
void main() {
  group('preflightBackend (injected)', () {
    test('non-macOS fails closed before any lookup', () async {
      final check = await preflightBackend(
        platform: () => 'linux',
        runner: _okRunner,
        which: (_) => '/usr/bin/sandbox-exec',
      );
      expect(check.ok, isFalse);
      expect(check.detail, contains('not macOS'));
    });

    test('missing sandbox-exec fails closed', () async {
      final check = await preflightBackend(
        platform: () => 'macos',
        runner: _okRunner,
        which: (_) => null,
      );
      expect(check.ok, isFalse);
      expect(check.detail, contains('sandbox-exec not found on PATH'));
    });

    test('backend that cannot launch fails closed', () async {
      final check = await preflightBackend(
        platform: () => 'macos',
        runner: (exe, args) async =>
            const CommandOutcome(exitCode: null, stdout: '', stderr: 'boom'),
        which: (_) => '/usr/bin/sandbox-exec',
      );
      expect(check.ok, isFalse);
      expect(check.detail, contains('could not run'));
    });

    test('rejecting backend fails closed with stderr detail', () async {
      final check = await preflightBackend(
        platform: () => 'macos',
        runner: (exe, args) async => const CommandOutcome(
          exitCode: 65,
          stdout: '',
          stderr: 'no version specified\nline 2\nline 3\nline 4',
        ),
        which: (_) => '/usr/bin/sandbox-exec',
      );
      expect(check.ok, isFalse);
      expect(check.detail, contains('exited 65'));
      expect(check.detail, contains('no version specified'));
    });

    test('accepting backend passes the trivial version-1 profile', () async {
      String? profile;
      final check = await preflightBackend(
        platform: () => 'macos',
        runner: (exe, args) async {
          profile = args[1];
          return const CommandOutcome(exitCode: 0, stdout: '', stderr: '');
        },
        which: (_) => '/usr/bin/sandbox-exec',
      );
      expect(check.ok, isTrue);
      expect(profile, contains('(version 1)(allow default)'));
    });
  });

  group('whichPathIn', () {
    late io.Directory tmp;
    setUp(() => tmp = io.Directory.systemTemp.createTempSync('which_ut'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String bin(String name) => '${tmp.path}/$name';

    String put(String dir, String name, {bool exec = true}) {
      final p = '$dir/$name';
      io.File(p)
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
      if (exec) io.Process.runSync('chmod', ['+x', p]);
      return p;
    }

    test('absolute executable name is returned as-is', () {
      final p = put(bin('abs'), 'tool');
      expect(whichPathIn(p, bin('unused')), p);
    });

    test('absolute non-executable name is rejected', () {
      final p = put(bin('abs'), 'tool', exec: false);
      expect(whichPathIn(p, bin('unused')), isNull);
    });

    test('absolute missing name is null', () {
      expect(whichPathIn('${bin('abs')}/nope', bin('unused')), isNull);
    });

    test('first PATH entry holding the name wins', () {
      put(bin('a'), 'tool');
      put(bin('b'), 'tool');
      expect(
        whichPathIn('tool', '${bin('a')}:${bin('b')}'),
        '${bin('a')}/tool',
      );
    });

    test('non-executable hit keeps searching later entries', () {
      put(bin('a'), 'tool', exec: false);
      put(bin('b'), 'tool');
      expect(
        whichPathIn('tool', '${bin('a')}:${bin('b')}'),
        '${bin('b')}/tool',
      );
    });

    test('name only in a later entry is found', () {
      put(bin('b'), 'tool');
      expect(
        whichPathIn('tool', '${bin('a')}:${bin('b')}'),
        '${bin('b')}/tool',
      );
    });

    test('empty and whitespace-only entries are skipped, not rooted', () {
      put(bin('b'), 'tool');
      expect(whichPathIn('tool', ' : :${bin('b')}:'), '${bin('b')}/tool');
    });

    test('not found anywhere is null', () {
      expect(whichPathIn('tool', '${bin('a')}:${bin('b')}'), isNull);
      expect(whichPathIn('tool', ''), isNull);
    });
  });
}

Future<CommandOutcome> _okRunner(String exe, List<String> args) async =>
    const CommandOutcome(exitCode: 0, stdout: '', stderr: '');
