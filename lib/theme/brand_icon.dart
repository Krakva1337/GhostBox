import 'package:flutter/material.dart';
import 'dart:typed_data';

import 'dart:ui' as ui;

Future<Uint8List> renderCustomGhostIcon(
    Color foreground, Color background) async {
  const size = Size.square(512);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  _GhostBoxIconPainter(foreground: foreground, background: background)
      .paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(512, 512);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

/// GhostBox launcher mark. Presets use checked-in PNGs; custom colors are
/// rendered directly so the user can create a distinct icon without changing
/// the application theme.
class GhostBoxBrandIcon extends StatelessWidget {
  const GhostBoxBrandIcon({
    super.key,
    required this.variant,
    required this.size,
    required this.foreground,
    required this.background,
  });

  final String variant;
  final double size;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * .22),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          reverseDuration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: .88, end: 1).animate(CurvedAnimation(
                  parent: animation, curve: Curves.easeOutCubic)),
              child: child,
            ),
          ),
          child: variant == 'custom'
              ? CustomPaint(
                  key: const ValueKey('icon-custom'),
                  size: Size.square(size),
                  painter: _GhostBoxIconPainter(
                      foreground: foreground, background: background),
                )
              : Image.asset(
                  variant == 'classic'
                      ? 'assets/icons/classic.png'
                      : 'assets/icons/$variant.png',
                  key: ValueKey('icon-$variant'),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
        ),
      );
}

class _GhostBoxIconPainter extends CustomPainter {
  const _GhostBoxIconPainter(
      {required this.foreground, required this.background});

  final Color foreground;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 64;
    canvas.save();
    canvas.scale(scale, scale);
    final bg = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(background, Colors.white, .12) ?? background,
          background,
        ],
      ).createShader(const Rect.fromLTWH(0, 0, 64, 64));
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(0, 0, 64, 64), const Radius.circular(19.24)),
        bg);

    final body = Path()
      ..moveTo(17.6, 22.4)
      ..arcToPoint(const Offset(46.4, 22.4),
          radius: const Radius.circular(14.4))
      ..lineTo(46.4, 30)
      ..cubicTo(46.4, 40, 49, 44, 48.7, 50.1)
      ..cubicTo(48.7, 54, 46.6, 56, 44.5, 56)
      ..cubicTo(41, 56, 38.8, 52, 38, 46.5)
      ..cubicTo(37.9, 45, 37.1, 45, 37, 46.5)
      ..cubicTo(36.4, 52, 35, 57, 32, 57)
      ..cubicTo(29, 57, 27.6, 52, 27, 46.5)
      ..cubicTo(26.9, 45, 26.1, 45, 26, 46.5)
      ..cubicTo(25.2, 52, 23, 56, 19.5, 56)
      ..cubicTo(17.4, 56, 15.3, 54, 15.3, 50.1)
      ..cubicTo(15, 44, 17.6, 40, 17.6, 30)
      ..close();
    canvas.drawPath(body, Paint()..color = foreground);

    final eyeColor = background.computeLuminance() > .42
        ? const Color(0xFF182033)
        : const Color(0xFF11151E);
    final eyes = Paint()..color = eyeColor;
    canvas.drawOval(
        Rect.fromCenter(center: Offset(26.9, 21), width: 6.6, height: 7.4),
        eyes);
    canvas.drawOval(
        Rect.fromCenter(center: Offset(37.1, 21), width: 6.6, height: 7.4),
        eyes);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GhostBoxIconPainter oldDelegate) =>
      foreground != oldDelegate.foreground ||
      background != oldDelegate.background;
}
