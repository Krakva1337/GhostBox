/// Build metadata shared by the UI and every outbound GhostBox request.
class AppVersion {
  AppVersion._();

  static const version = String.fromEnvironment(
    'GHOSTBOX_VERSION',
    defaultValue: '2.3.3',
  );
  static const build = String.fromEnvironment(
    'GHOSTBOX_BUILD',
    defaultValue: '35',
  );

  static String get userAgent => 'GhostBox/$version (build $build)';
  static String get versionAndBuild => '$version+$build';
}
