import 'dart:convert';

import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/resolver.dart';
import 'package:test/test.dart';

/// `--yaml -` stdin plumbing: content is read to EOF, empty/whitespace
/// input fails closed (ConfigException).
void main() {
  test('readManifestStdin reads stdin to EOF', () async {
    final text = await readManifestStdin(
      source: Stream<List<int>>.fromIterable([
        utf8.encode('apiVersion: cube-sandbox/v1\n'),
        utf8.encode('kind: Harness\n'),
      ]),
    );
    expect(text, 'apiVersion: cube-sandbox/v1\nkind: Harness\n');
  });

  test('readManifestStdin: empty stdin fails closed', () async {
    await expectLater(
      readManifestStdin(source: const Stream<List<int>>.empty()),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          '--yaml -: stdin is empty',
        ),
      ),
    );
  });

  test('readManifestStdin: whitespace-only stdin fails closed', () async {
    await expectLater(
      readManifestStdin(
        source: Stream<List<int>>.fromIterable([utf8.encode(' \n\n')]),
      ),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('stdin is empty'),
        ),
      ),
    );
  });
}
