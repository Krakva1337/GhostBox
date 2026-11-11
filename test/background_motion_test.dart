import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghostbox/theme/background_effects.dart';
import 'package:ghostbox/theme/theme_controller.dart';

void main() {
  testWidgets(
      'effects animate, survive rapid switches, and freeze when requested',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeController.instance;
    theme.setReducedMotion(false);
    await theme.setBackgroundEffect('stars');
    final key = GlobalKey();
    Widget scene({bool animated = true, bool disableAnimations = false}) =>
        MaterialApp(
            home: MediaQuery(
                data: MediaQueryData(disableAnimations: disableAnimations),
                child: Center(
                    child: SizedBox(
                        width: 360,
                        height: 640,
                        child: RepaintBoundary(
                            key: key,
                            child: GhostBoxBackgroundEffect(
                                animated: animated))))));
    Future<Uint8List> pixels() async => (await tester.runAsync(() async {
          final image = await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
          final bytes =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          return bytes!.buffer.asUint8List();
        }))!;
    await tester.pumpWidget(scene());
    await tester.pump();
    final first = await pixels();
    await tester.pump(const Duration(seconds: 1));
    expect(listEquals(first, await pixels()), isFalse,
        reason: 'Stars must move and twinkle');
    await theme.setBackgroundEffect('none');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect((await pixels()).any((byte) => byte != 0), isTrue,
        reason: 'Switching off must fade the outgoing effect');
    await tester.pump(const Duration(seconds: 2));
    expect((await pixels()).every((byte) => byte == 0), isTrue);
    await theme.setBackgroundEffect('stars');
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    for (final effect in ['snow', 'aurora', 'orbs', 'none', 'stars', 'snow']) {
      await theme.setBackgroundEffect(effect);
      await tester.pump(const Duration(milliseconds: 90));
    }
    await tester.pump(const Duration(seconds: 2));
    expect(theme.backgroundEffect, 'snow');
    final snow = await pixels();
    await tester.pump(const Duration(seconds: 1));
    expect(listEquals(snow, await pixels()), isFalse,
        reason: 'Snow must keep falling');
    expect(tester.takeException(), isNull);
    theme.setReducedMotion(true);
    await tester.pumpAndSettle();
    final frozen = await pixels();
    await tester.pump(const Duration(seconds: 2));
    expect(listEquals(frozen, await pixels()), isTrue,
        reason: 'Reduced motion must freeze particles');
    theme.setReducedMotion(false);
    await tester.pumpWidget(scene(animated: false));
    await tester.pumpAndSettle();
    final globalOff = await pixels();
    await tester.pump(const Duration(seconds: 2));
    expect(listEquals(globalOff, await pixels()), isTrue);
    await tester.pumpWidget(scene(disableAnimations: true));
    await tester.pumpAndSettle();
    await theme.setBackgroundEffect('stars');
    await tester.pumpAndSettle();
    final systemOff = await pixels();
    await tester.pump(const Duration(seconds: 2));
    expect(listEquals(systemOff, await pixels()), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
