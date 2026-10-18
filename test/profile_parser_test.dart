import 'package:flutter_test/flutter_test.dart';
import 'package:ghostbox/services/profile_parser.dart';

void main() {
  final parser = ProfileParser();

  test('parses vless links', () {
    final result = parser.parse(
      'vless://123e4567-e89b-12d3-a456-426614174000@example.com:443?type=ws&security=tls#Demo',
    );
    expect(result.single.address, 'example.com');
    expect(result.single.port, 443);
    expect(result.single.network, 'ws');
  });

  test('parses json profiles', () {
    final result = parser.parse('[{"name":"Test","address":"127.0.0.1","port":1080}]');
    expect(result.single.name, 'Test');
    expect(result.single.port, 1080);
  });
}
