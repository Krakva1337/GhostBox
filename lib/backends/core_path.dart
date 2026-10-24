import 'dart:ffi' show Abi;
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
  if (bundled.existsSync()) return bundled.path;

  // Desktop build scripts keep host cores under vendor/<platform>/<arch>/bin.
  // Resolve those directly for Flutter development runs, where the app bundle
  // does not yet contain the packaged vendor/bin directory.
  if (Platform.isMacOS) {
    final arch = Abi.current() == Abi.macosArm64 ? 'arm64' : 'amd64';
    final developmentCore = File('vendor/macos/$arch/bin/$name');
    if (developmentCore.existsSync()) return developmentCore.absolute.path;
  }

  return File(relative).absolute.path;
}
