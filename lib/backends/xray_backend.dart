import 'core_path.dart';
import '../core/core_process.dart';
import '../core/vpn_backend.dart';

class XrayBackend extends CoreProcessBackend implements VpnBackend {
  XrayBackend({String root = 'vendor'})
      : super(
          name: 'xray',
          executable: coreExecutable('xray', root),
          configPath: '$root/config/xray.json',
        );
}
