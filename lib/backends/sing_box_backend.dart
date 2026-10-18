import 'core_path.dart';
import '../core/core_process.dart';
import '../core/vpn_backend.dart';

class SingBoxBackend extends CoreProcessBackend implements VpnBackend {
  SingBoxBackend({String root = 'vendor'})
      : super(
          name: 'sing-box',
          executable: coreExecutable('sing-box', root),
          configPath: '$root/config/sing-box.json',
        );
}
