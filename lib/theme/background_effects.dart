import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme_controller.dart';

class GhostBoxBackgroundEffect extends StatefulWidget {
  const GhostBoxBackgroundEffect({super.key, this.animated = true});
  final bool animated;

  @override
  State<GhostBoxBackgroundEffect> createState() =>
      _GhostBoxBackgroundEffectState();
}

class _GhostBoxBackgroundEffectState extends State<GhostBoxBackgroundEffect>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _effectNames = ['none', 'stars', 'snow', 'aurora', 'orbs'];
  final ThemeController _theme = ThemeController.instance;
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 48),
  )..repeat();
  late final AnimationController _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 1,
  );
  late Set<String> _selectedEffects = Set.of(_theme.activeBackgroundEffects);
  late List<double> _from = _weightsFor(_selectedEffects);
  late List<double> _to = List<double>.of(_from);
  bool _motionAllowed = true;
  bool _appVisible = true;

  List<double> _weightsFor(Set<String> selected) => List<double>.generate(
      _effectNames.length, (i) => selected.contains(_effectNames[i]) ? 1 : 0);

  List<double> _weights() {
    final t = Curves.easeInOutCubic.transform(_transition.value);
    return List<double>.generate(
      _effectNames.length,
      (i) => _from[i] + (_to[i] - _from[i]) * t,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _theme.addListener(_themeChanged);
    _transition.addStatusListener((status) {
      if (status == AnimationStatus.completed && _selectedEffects.isEmpty) {
        _phase.stop();
      }
    });
    if (_selectedEffects.isEmpty) _phase.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant GhostBoxBackgroundEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animated != widget.animated) _syncMotion();
  }

  void _syncMotion() {
    final allowed = _appVisible &&
        widget.animated &&
        TickerMode.of(context) &&
        !_theme.reduceMotion &&
        !MediaQuery.disableAnimationsOf(context);
    if (_motionAllowed == allowed) return;
    _motionAllowed = allowed;
    if (allowed) {
      if (_selectedEffects.isNotEmpty) _phase.repeat();
      if (_transition.value < 1) _transition.forward();
    } else {
      _phase.stop();
      _from = _weights();
      _to = List<double>.of(_from);
      _transition
        ..stop()
        ..value = 1;
    }
  }

  void _themeChanged() {
    if (!mounted) return;
    final next = Set<String>.of(_theme.activeBackgroundEffects);
    if (next.length != _selectedEffects.length ||
        !next.containsAll(_selectedEffects)) {
      _from = _weights();
      _selectedEffects = next;
      _to = _weightsFor(next);
      if (_motionAllowed) {
        if (next.isNotEmpty && !_phase.isAnimating) {
          _phase.repeat();
        }
        _transition.forward(from: 0);
      } else {
        _from = List<double>.of(_to);
        _transition
          ..stop()
          ..value = 1;
      }
    }
    // Accent can change without changing the selected background effect.
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appVisible = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncMotion();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _theme.removeListener(_themeChanged);
    _phase.dispose();
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncMotion();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _EffectPainter(
            accent: _theme.accent,
            phase: _phase,
            transition: _transition,
            from: _from,
            to: _to,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// Paints all background layers in one pass. Animation ticks invalidate the
/// render object directly, so they never rebuild or relayout the widget tree.
class _EffectPainter extends CustomPainter {
  _EffectPainter({
    required this.accent,
    required this.phase,
    required this.transition,
    required this.from,
    required this.to,
  }) : super(repaint: Listenable.merge([phase, transition]));

  final Color accent;
  final Animation<double> phase;
  final Animation<double> transition;
  final List<double> from;
  final List<double> to;

  final Paint _particlePaint = Paint()..isAntiAlias = true;
  final Paint _rayPaint = Paint()
    ..isAntiAlias = true
    ..strokeWidth = .65
    ..strokeCap = StrokeCap.round;
  final Paint _linePaint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _fillPaint = Paint()..isAntiAlias = true;
  final Path _auroraPath = Path();
  Size? _auroraSize;
  final List<Paint> _auroraPaints = [];

  static final _stars = List.generate(112, (i) {
    final r = math.Random(0x6B057 + i * 37);
    return (
      x: r.nextDouble(),
      y: r.nextDouble(),
      radius: .45 + r.nextDouble() * 1.35,
      phase: r.nextDouble() * math.pi * 2,
      drift: r.nextDouble() * math.pi * 2,
      speedX: 1 + i % 5,
      speedY: 1 + (i * 3) % 6,
      amplitude: .012 + r.nextDouble() * .026,
    );
  });
  static final _flakes = List.generate(192, (i) {
    final r = math.Random(0x5A0F + i * 53);
    return (
      x: r.nextDouble(),
      y: r.nextDouble(),
      radius: .95 + r.nextDouble() * 2.35,
      speed: .7 + r.nextDouble() * 1.7,
      sway: .012 + r.nextDouble() * .035,
      phase: r.nextDouble() * math.pi * 2,
      wind: 1 + i % 7,
      curl: 1 + (i * 3) % 5,
      swayPhase: r.nextDouble() * math.pi * 2,
    );
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final progress = Curves.easeInOutCubic.transform(transition.value);
    final t = phase.value;
    for (var effect = 1; effect < from.length; effect++) {
      final opacity = from[effect] + (to[effect] - from[effect]) * progress;
      if (opacity <= .001) continue;
      switch (effect) {
        case 1:
          _paintStars(canvas, size, t, opacity);
        case 2:
          _paintSnow(canvas, size, t, opacity);
        case 3:
          _paintAurora(canvas, size, t, opacity);
        case 4:
          _paintOrbits(canvas, size, t, opacity);
      }
    }
  }

  int _particleCount(Size size, int maximum) =>
      (size.width * size.height / 2400).round().clamp(54, maximum);

  void _paintStars(
      Canvas canvas, Size size, double phaseValue, double opacity) {
    final t = phaseValue * math.pi * 2;
    final count = _particleCount(size, 112);
    for (var i = 0; i < count; i++) {
      final star = _stars[i];
      final x = star.x +
          math.sin(t * star.speedX + star.drift) * star.amplitude +
          math.sin(t * (star.speedX * .37) + star.phase) * star.amplitude * .34;
      final y = star.y +
          math.cos(t * star.speedY + star.phase) * star.amplitude * .72 +
          math.sin(t * (star.speedY * .29) + star.drift) * star.amplitude * .28;
      final shimmer =
          .19 + .73 * (.5 + .5 * math.sin(t * (1 + i % 9) + star.phase));
      final center = Offset(x * size.width, y * size.height);
      _particlePaint.color = accent.withValues(alpha: shimmer * opacity);
      canvas.drawCircle(center, star.radius, _particlePaint);
      if (star.radius > 1.25 && shimmer > .5) {
        final ray = star.radius * 2.5;
        _rayPaint.color =
            accent.withValues(alpha: (shimmer - .5) / .33 * opacity * .42);
        canvas.drawLine(
          center.translate(-ray, 0),
          center.translate(ray, 0),
          _rayPaint,
        );
        canvas.drawLine(
          center.translate(0, -ray),
          center.translate(0, ray),
          _rayPaint,
        );
      }
    }
  }

  void _paintSnow(Canvas canvas, Size size, double phaseValue, double opacity) {
    final t = phaseValue * math.pi * 2;
    final count = _particleCount(size, 192);
    for (var i = 0; i < count; i++) {
      final flake = _flakes[i];
      const margin = 18.0;
      final span = size.height + margin * 2;
      final travel = phaseValue * flake.speed;
      final y = ((flake.y + travel) % 1) * span - margin;
      // Summed low-frequency oscillations approximate changing gusts and
      // per-flake eddies without random jumps or per-frame allocations.
      final gust = math.sin(t * flake.wind + flake.phase) * .62 +
          math.sin(t * (flake.wind * .37) + flake.swayPhase) * .38;
      final curl = math.sin(t * flake.curl + flake.swayPhase + travel * 2.4);
      final x = flake.x + (gust + curl * .5) * flake.sway;
      final center = Offset(x * size.width, y);
      final alpha =
          (.46 + .36 * (.5 + .5 * math.sin(t * (1 + i % 4) + flake.phase))) *
              opacity;
      final radius =
          flake.radius * (1 + .10 * math.sin(t * (1 + i % 3) + flake.phase));
      // Crisp snow uses a single inexpensive draw per flake; size and alpha
      // provide depth without costly blur filters or offscreen layers.
      _particlePaint.color = Colors.white.withValues(alpha: alpha);
      canvas.drawCircle(center, radius, _particlePaint);
    }
  }

  void _paintAurora(
      Canvas canvas, Size size, double phaseValue, double opacity) {
    final t = phaseValue * math.pi * 2;
    if (_auroraSize != size) {
      _auroraSize = size;
      _auroraPaints.clear();
      for (var band = 0; band < 3; band++) {
        final color = Color.lerp(accent, const Color(0xFF56E0D0), band / 3)!;
        _auroraPaints.add(Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = size.height * .13
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0),
              color.withValues(alpha: .12),
              color.withValues(alpha: 0)
            ],
          ).createShader(Rect.fromLTWH(
              0, -size.height * .2, size.width, size.height * .4)));
      }
    }
    for (var band = 0; band < 3; band++) {
      final y = size.height * (.44 + band * .11 + math.sin(t + band) * .035);
      _auroraPath
        ..reset()
        ..moveTo(-size.width * .1, size.height * .08)
        ..cubicTo(size.width * .24, -size.height * .18, size.width * .6,
            size.height * .17, size.width * 1.1, -size.height * .12);
      // Modulate a cached gradient instead of a full-screen blur layer.
      _auroraPaints[band].color = Colors.white.withValues(alpha: opacity);
      canvas.save();
      canvas.translate(0, y);
      canvas.drawPath(_auroraPath, _auroraPaints[band]);
      canvas.restore();
    }
  }

  void _paintOrbits(
      Canvas canvas, Size size, double phaseValue, double opacity) {
    final center = Offset(size.width * .5, size.height * .47);
    final scale = math.min(size.width, size.height);
    for (var ring = 0; ring < 3; ring++) {
      final rect = Rect.fromCenter(
        center: center,
        width: scale * (.56 + ring * .2),
        height: scale * (.20 + ring * .1),
      );
      _linePaint
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: (.075 - ring * .012) * opacity);
      canvas.drawOval(rect, _linePaint);
      final angle = phaseValue * math.pi * 2 * (ring.isEven ? 1 : -1) + ring;
      final node = Offset(
        center.dx + math.cos(angle) * rect.width / 2,
        center.dy + math.sin(angle) * rect.height / 2,
      );
      _fillPaint.color = accent.withValues(alpha: .48 * opacity);
      canvas.drawCircle(node, 2.1 + ring * .4, _fillPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _EffectPainter old) =>
      accent != old.accent ||
      !identical(phase, old.phase) ||
      !identical(transition, old.transition) ||
      !identical(from, old.from) ||
      !identical(to, old.to);
}
