import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghostbox/theme/theme_controller.dart';
import 'package:ghostbox/theme/theme_settings_panel.dart';
import 'package:ghostbox/theme/background_effects.dart';

void main() {
  testWidgets(
      'bundled font and effect controls save choices on a narrow screen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ThemeController.instance;
    controller.setReducedMotion(true);
    await tester.pumpWidget(ThemeScope(
      controller: controller,
      child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => MaterialApp(
                theme: controller.theme,
                home: Scaffold(
                    body: Stack(children: [
                  const Positioned.fill(child: GhostBoxBackgroundEffect()),
                  const SingleChildScrollView(
                      child: Padding(
                          padding: EdgeInsets.all(16),
                          child: ThemeSettingsPanel())),
                ])),
              )),
    ));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'DejaVu Serif'));
    await tester.pumpAndSettle();
    expect(controller.selectedFontFamily, 'DejaVu Serif');
    expect(controller.theme.textTheme.bodyMedium?.fontFamily, 'DejaVu Serif');
    expect(
        (await SharedPreferences.getInstance())
            .getString('appearance.fontFamily'),
        'DejaVu Serif');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Северное сияние'));
    await tester.pumpAndSettle();
    expect(controller.backgroundEffect, 'aurora');
    expect(
        (await SharedPreferences.getInstance())
            .getString('appearance.backgroundEffect'),
        'aurora');
    expect(tester.takeException(), isNull);
    // An effect remains visible in reduced motion, without a ticking animation.
    expect(find.byType(GhostBoxBackgroundEffect), findsOneWidget);
    controller.setReducedMotion(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    controller.setReducedMotion(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
