import 'package:flutter_test/flutter_test.dart';
import 'package:ghostbox/services/github_updater.dart';

void main() {
  final updater = GitHubUpdater();

  test('normalizes short prerelease tags without losing channel suffix', () {
    expect(updater.normalizeReleaseTag('v2.4-beta.2'), '2.4.0-beta.2');
    expect(updater.normalizeReleaseTag('V2.4.1'), '2.4.1');
  });

  test('sorts semantic versions including prerelease identifiers', () {
    expect(updater.compareVersions('2.0.0-alpha.2', '2.0.0-alpha.10'),
        lessThan(0));
    expect(updater.compareVersions('2.0.0-alpha', '2.0.0'), lessThan(0));
    expect(updater.compareVersions('2.0.0+build.1', '2.0.0+build.2'), 0);
    expect(updater.compareVersions('2.1.0', '2.0.9'), greaterThan(0));
  });
}
