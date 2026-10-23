import 'dart:async';

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

/// Adds a short ease to wheel scrolling while retaining native drag physics.
class SmoothScrollController extends ScrollController {
  SmoothScrollController({required this.enabled});

  final bool Function() enabled;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics,
          ScrollContext context, ScrollPosition? oldPosition) =>
      _SmoothScrollPosition(
        enabled: enabled,
        physics: physics,
        context: context,
        initialPixels: initialScrollOffset,
        keepScrollOffset: keepScrollOffset,
        oldPosition: oldPosition,
        debugLabel: debugLabel,
      );
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required this.enabled,
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final bool Function() enabled;
  double? _wheelTarget;
  int _wheelGeneration = 0;

  void _resetWheel() {
    _wheelGeneration++;
    _wheelTarget = null;
  }

  @override
  void pointerScroll(double delta) {
    if (!enabled() || !hasContentDimensions || delta == 0) {
      _resetWheel();
      super.pointerScroll(delta);
      return;
    }

    final remaining = (_wheelTarget ?? pixels) - pixels;
    final reversing = remaining.abs() > .5 && remaining.sign != delta.sign;
    final base = activity is DrivenScrollActivity && !reversing
        ? _wheelTarget ?? pixels
        : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) {
      if (reversing) goIdle();
      return;
    }

    _wheelTarget = target;
    final generation = ++_wheelGeneration;
    updateUserScrollDirection(
        delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse);
    unawaited(super
        .animateTo(target,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic)
        .whenComplete(() {
      if (generation == _wheelGeneration) _wheelTarget = null;
    }));
  }

  @override
  void beginActivity(ScrollActivity? newActivity) {
    if (newActivity is! DrivenScrollActivity) _resetWheel();
    super.beginActivity(newActivity);
  }

  @override
  Future<void> animateTo(double to,
      {required Duration duration, required Curve curve}) {
    _resetWheel();
    return super.animateTo(to, duration: duration, curve: curve);
  }

  @override
  void jumpTo(double value) {
    _resetWheel();
    super.jumpTo(value);
  }
}
