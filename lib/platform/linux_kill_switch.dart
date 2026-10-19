import 'dart:io';

import '../models/server_profile.dart';

/// Linux nftables guard for the desktop TUN interface.
///
/// The dedicated table remains installed after GhostBox exits so traffic stays
/// blocked until the user turns the feature off. Only loopback, the TUN device,
/// DHCP renewal, and the selected VPN endpoint are allowed out.
class LinuxKillSwitch {
  static const _table = 'ghostbox_killswitch';

  static Future<ServerProfile> arm(ServerProfile profile,
      {String? knownEndpoint}) async {
    final knownAddress =
        knownEndpoint == null ? null : InternetAddress.tryParse(knownEndpoint);
    final endpoint = knownAddress?.address ?? await _resolve(profile.address);
    final address = InternetAddress.tryParse(endpoint)!;
    final family = address.type == InternetAddressType.IPv4 ? 'ip' : 'ip6';
    final existed = await _tableExists();
    final delete = existed ? 'delete table inet $_table\n' : '';
    final script = '''
$delete
table inet $_table {
  chain output {
    type filter hook output priority -150; policy drop;
    oifname "lo" accept
    oifname "ghostbox0" accept
    $family daddr $endpoint tcp dport ${profile.port} accept
    $family daddr $endpoint udp dport ${profile.port} accept
    udp dport 67 accept
    udp sport 68 accept
    udp dport 547 accept
  }
}
''';
    await _runPrivilegedNft(script);
    return withEndpoint(profile, endpoint);
  }

  static ServerProfile withEndpoint(ServerProfile profile, String endpoint) =>
      ServerProfile(
        id: profile.id,
        name: profile.name,
        protocol: profile.protocol,
        address: endpoint,
        port: profile.port,
        uuid: profile.uuid,
        network: profile.network,
        security: profile.security,
        raw: profile.raw,
      );

  static Future<void> disarm() async {
    if (!await _tableExists()) return;
    await _runPrivilegedNft('delete table inet $_table\n');
  }

  static Future<String> _resolve(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return literal.address;
    final addresses =
        await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
    if (addresses.isEmpty)
      throw SocketException('Не удалось найти IP сервера $host');
    return addresses.first.address;
  }

  static Future<bool> _tableExists() async {
    final result =
        await Process.run('pkexec', ['nft', 'list', 'table', 'inet', _table]);
    if (result.exitCode == 0) return true;
    final error = '${result.stderr} ${result.stdout}';
    if (error.contains('No such file or directory') ||
        error.contains('does not exist')) return false;
    throw ProcessException('pkexec nft', ['list', 'table', 'inet', _table],
        '${result.stderr}'.trim(), result.exitCode);
  }

  static Future<void> _runPrivilegedNft(String script) async {
    final process = await Process.start('pkexec', ['nft', '-f', '-']);
    process.stdin.write(script);
    await process.stdin.close();
    final stdout =
        await process.stdout.transform(systemEncoding.decoder).join();
    final stderr =
        await process.stderr.transform(systemEncoding.decoder).join();
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw ProcessException('pkexec nft', ['-f', '-'],
          (stderr.isEmpty ? stdout : stderr).trim(), exitCode);
    }
  }
}
