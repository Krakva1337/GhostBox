import 'dart:io';

/// Installed bundles take priority; development launches use workspace/vendor.
String coreExecutable(String name, String root) {
  final suffix = Platform.isWindows ? '.exe' : '';
  final relative = '$root/bin/$name$suffix';
  if (Directory(root).isAbsolute) return relative;
  final override = Platform.environment['GHOSTBOX_VENDOR_DIR'];
  if (override != null && override.isNotEmpty) {
    final userCore = File('$override/bin/$name$suffix');
    if (userCore.existsSync()) return userCore.path;
  }
  final bundled =
      File('${File(Platform.resolvedExecutable).parent.path}/$relative');
  return bundled.existsSync() ? bundled.path : File(relative).absolute.path;
}
