/// Build metadata shared by the UI and every outbound GhostBox request.
class AppVersion {
  AppVersion._();

  static const version = String.fromEnvironment(
    'GHOSTBOX_VERSION',
    defaultValue: '1.4.8-alpha',
  );
  static const build = String.fromEnvironment(
    'GHOSTBOX_BUILD',
    defaultValue: '24',
  );

  static String get userAgent => 'GhostBox/$version (build $build)';
  static String get versionAndBuild => '$version+$build';
}
