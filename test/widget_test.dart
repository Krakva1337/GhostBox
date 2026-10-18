import 'package:flutter_test/flutter_test.dart';
import 'package:ghostbox/app.dart';

void main() {
  testWidgets('GhostBox renders server screen', (tester) async {
    await tester.pumpWidget(const GhostBoxApp());
    expect(find.text('KrakvaVPN'), findsWidgets);
    expect(find.text('Сервера'), findsOneWidget);
  });
}
