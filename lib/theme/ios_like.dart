import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'ios_like_tokens.dart';
import 'theme_controller.dart';

/// A quiet, translucent surface for the iOS-Like appearance.
///
/// Blur is clipped to this surface so large settings lists do not create an
/// expensive full-screen backdrop layer.
class IosGlassSurface extends StatelessWidget {
  const IosGlassSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = 24,
    this.tint,
    this.blur = 18,
    this.blurEnabled = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? tint;
  final double blur;
  final bool blurEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context) ||
        ThemeController.instance.reduceMotion;
    final radius = BorderRadius.circular(borderRadius);
    final appearance = ThemeController.instance;
    final enabled = blurEnabled && appearance.glassPanelsEnabled;
    final strength = appearance.glassStrength.clamp(0.0, 1.0);
    final base = tint ?? theme.colorScheme.surface;
    final useGlass = enabled && !reduceMotion;
    final surface = ClipRRect(
      borderRadius: radius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: base.withValues(
              alpha: useGlass ? (dark ? .86 : .94) - strength * .25 : 1),
          borderRadius: radius,
          border: Border.all(
            color: theme.colorScheme.onSurface.withValues(alpha: .10),
            width: 1,
          ),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
    if (!useGlass) return surface;
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: (blur * (.6 + strength)).clamp(0, 24),
          sigmaY: (blur * (.6 + strength)).clamp(0, 24),
        ),
        child: surface,
      ),
    );
  }
}

/// Restrained connection button with a clear label and state description.
class IosLikeConnectionControl extends StatelessWidget {
  const IosLikeConnectionControl({
    super.key,
    required this.connected,
    required this.busy,
    required this.error,
    required this.title,
    required this.subtitle,
    required this.onPressed,
    this.blurEnabled = true,
  });

  final bool connected;
  final bool busy;
  final bool error;
  final String title;
  final String subtitle;
  final VoidCallback? onPressed;
  final bool blurEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context) ||
        ThemeController.instance.reduceMotion;
    final accent = error
        ? theme.colorScheme.error
        : connected
            ? const Color(0xFF42C98A)
            : theme.colorScheme.primary;
    final duration = Duration(
        milliseconds: reduceMotion
            ? 0
            : (260 / ThemeController.instance.transitionSpeed).round());
    return Semantics(
      button: true,
      liveRegion: busy || error,
      enabled: !busy && onPressed != null,
      label: '$title. $subtitle',
      onTap: busy ? null : onPressed,
      child: ExcludeSemantics(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  IosLikeTokens.space5,
                  IosLikeTokens.space5,
                  IosLikeTokens.space5,
                  IosLikeTokens.space4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    excludeSemantics: true,
                    child: Tooltip(
                      message: title,
                      child: Material(
                        color: Colors.transparent,
                        child: InkResponse(
                          onTap: busy ? null : onPressed,
                          radius: 64,
                          containedInkWell: true,
                          highlightShape: BoxShape.circle,
                          child: AnimatedContainer(
                            duration: duration,
                            curve: Curves.easeOutCubic,
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: accent.withValues(
                                  alpha: connected ? .15 : .09),
                              border: Border.all(
                                color: accent.withValues(
                                    alpha: connected ? .50 : .28),
                                width: 1.2,
                              ),
                            ),
                            child: Center(
                              child: AnimatedSwitcher(
                                duration: duration,
                                transitionBuilder: (child, animation) =>
                                    ScaleTransition(
                                  scale: animation,
                                  child: FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                                ),
                                child: busy && !reduceMotion
                                    ? SizedBox(
                                        key: const ValueKey('busy'),
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.4,
                                          color: accent,
                                        ),
                                      )
                                    : Icon(
                                        busy
                                            ? Icons.sync_rounded
                                            : Icons.power_settings_new_rounded,
                                        key: ValueKey((connected, busy)),
                                        size: 32,
                                        color: accent,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: IosLikeTokens.space3),
                  AnimatedSwitcher(
                    duration: duration,
                    child: Text(
                      title,
                      key: ValueKey(title),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: IosLikeTokens.sectionSize,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: IosLikeTokens.space1),
                  AnimatedSwitcher(
                    duration: duration,
                    child: Text(
                      subtitle,
                      key: ValueKey(subtitle),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: IosLikeTokens.secondarySize,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Minimal floating navigation shared by the compact and desktop layouts.
/// Supply localized labels and the same icon order as the host page.
class IosLikeNavigation extends StatefulWidget {
  const IosLikeNavigation({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.compact = false,
    this.blurEnabled = true,
  });

  final List<({IconData icon, String label})> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool compact;
  final bool blurEnabled;

  @override
  State<IosLikeNavigation> createState() => _IosLikeNavigationState();
}

class _IosLikeNavigationState extends State<IosLikeNavigation> {
  double? _dragIndex;
  bool _dragging = false;
  Size? _lastSize;

  int get _selected => widget.selectedIndex.clamp(0, widget.items.length - 1);

  @override
  void didUpdateWidget(covariant IosLikeNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.items.length != widget.items.length ||
        oldWidget.compact != widget.compact) {
      _dragIndex = null;
      _dragging = false;
    }
  }

  void _updateDrag(
    Offset position,
    Size size, {
    required double itemExtent,
    required double step,
  }) {
    if (widget.items.isEmpty) return;
    final axis = widget.compact ? position.dx : position.dy;
    final extent = widget.compact ? size.width : size.height;
    if (extent <= 0 || step <= 0) return;
    setState(() {
      _dragging = true;
      final centerExtent = widget.compact ? step : itemExtent;
      _dragIndex = ((axis - centerExtent / 2) / step)
          .clamp(0.0, (widget.items.length - 1).toDouble());
    });
  }

  double _labelHeight(
    BuildContext context,
    String label,
    TextStyle style,
    double maxWidth,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 2,
      ellipsis: '\u2026',
    )..layout(maxWidth: maxWidth.clamp(1, double.infinity));
    return painter.height;
  }

  void _finishDrag() {
    if (!_dragging) return;
    final destination = (_dragIndex ?? _selected).round();
    setState(() {
      _dragging = false;
      _dragIndex = null;
    });
    if (destination != _selected) widget.onSelected(destination);
  }

  void _cancelDrag() {
    if (!_dragging) return;
    setState(() {
      _dragging = false;
      _dragIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context) ||
        ThemeController.instance.reduceMotion;
    final index = _selected;
    final selectedColor = colorScheme.primary;
    final compact = widget.compact;
    final outerRadius =
        compact ? IosLikeTokens.sheetRadius : IosLikeTokens.cardRadius;
    final innerRadius = outerRadius - IosLikeTokens.space1;

    Widget contents({
      required double itemExtent,
      required double step,
      required double contentHeight,
    }) =>
        LayoutBuilder(builder: (context, bounds) {
          if (_lastSize != bounds.biggest) {
            final wasDragging = _dragging;
            _lastSize = bounds.biggest;
            if (wasDragging) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _cancelDrag();
              });
            }
          }
          final extent = compact ? bounds.maxWidth : contentHeight;
          final segment = compact ? extent / widget.items.length : step;
          final indicatorIndex =
              _dragging ? (_dragIndex ?? index.toDouble()) : index.toDouble();
          final indicatorWidth = compact ? segment : bounds.maxWidth;
          final indicatorHeight = itemExtent;
          final indicatorStretch = _dragging && !reduceMotion ? 2.0 : 0.0;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: compact
                ? (details) => _updateDrag(
                    details.localPosition, bounds.biggest,
                    itemExtent: itemExtent, step: segment)
                : null,
            onHorizontalDragUpdate: compact
                ? (details) => _updateDrag(
                    details.localPosition, bounds.biggest,
                    itemExtent: itemExtent, step: segment)
                : null,
            onHorizontalDragEnd: compact ? (_) => _finishDrag() : null,
            onVerticalDragStart: compact
                ? null
                : (details) => _updateDrag(
                    details.localPosition, bounds.biggest,
                    itemExtent: itemExtent, step: segment),
            onVerticalDragUpdate: compact
                ? null
                : (details) => _updateDrag(
                    details.localPosition, bounds.biggest,
                    itemExtent: itemExtent, step: segment),
            onVerticalDragEnd: compact ? null : (_) => _finishDrag(),
            onHorizontalDragCancel: compact ? _cancelDrag : null,
            onVerticalDragCancel: compact ? null : _cancelDrag,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedPositioned(
                  duration: Duration(
                    milliseconds: _dragging || reduceMotion
                        ? 0
                        : (220 / ThemeController.instance.transitionSpeed)
                            .round(),
                  ),
                  curve: Curves.easeOutCubic,
                  left: compact
                      ? indicatorIndex * segment - indicatorStretch / 2
                      : 0,
                  top: compact
                      ? -indicatorStretch / 2
                      : indicatorIndex * segment - indicatorStretch / 2,
                  width: compact
                      ? indicatorWidth + indicatorStretch
                      : indicatorWidth,
                  height: compact
                      ? indicatorHeight + indicatorStretch
                      : indicatorHeight + indicatorStretch,
                  child: _SelectionSubstrate(
                    radius: innerRadius,
                    color: selectedColor,
                    blur: widget.blurEnabled && !reduceMotion && _dragging,
                    dragging: _dragging,
                  ),
                ),
                compact
                    ? Row(
                        children: [
                          for (var i = 0; i < widget.items.length; i++)
                            Expanded(
                              child: _NavigationItem(
                                item: widget.items[i],
                                selected: i == index,
                                compact: true,
                                reduceMotion: reduceMotion,
                                selectedColor: selectedColor,
                                onTap: () => widget.onSelected(i),
                              ),
                            ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < widget.items.length; i++) ...[
                            if (i > 0)
                              const SizedBox(height: IosLikeTokens.space1),
                            SizedBox(
                              height: itemExtent,
                              child: _NavigationItem(
                                item: widget.items[i],
                                selected: i == index,
                                compact: false,
                                reduceMotion: reduceMotion,
                                selectedColor: selectedColor,
                                onTap: () => widget.onSelected(i),
                              ),
                            ),
                          ],
                        ],
                      ),
              ],
            ),
          );
        });

    return LayoutBuilder(builder: (context, constraints) {
      final maxWidth =
          constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
      final contentWidth = compact
          ? (maxWidth - 2 * IosLikeTokens.space1).clamp(1, double.infinity)
          : (maxWidth - 2 * IosLikeTokens.space1).clamp(1, double.infinity);
      final textTheme = Theme.of(context).textTheme;
      final itemExtent = compact
          ? widget.items.fold<double>(58, (height, item) {
              final labelHeight = _labelHeight(
                context,
                item.label,
                textTheme.labelSmall!,
                contentWidth / widget.items.length - 2 * IosLikeTokens.space2,
              );
              final requiredHeight = 20 +
                  IosLikeTokens.space1 +
                  labelHeight +
                  2 * IosLikeTokens.space1;
              return height > requiredHeight ? height : requiredHeight;
            })
          : widget.items.fold<double>(72, (height, item) {
              final labelHeight = _labelHeight(
                context,
                item.label,
                textTheme.labelMedium!,
                contentWidth - 2 * IosLikeTokens.space3,
              );
              final requiredHeight = 21 +
                  IosLikeTokens.space2 +
                  labelHeight +
                  2 * IosLikeTokens.space2;
              return height > requiredHeight ? height : requiredHeight;
            });
      const gap = IosLikeTokens.space1;
      final step = itemExtent + (compact ? 0 : gap);
      final contentHeight = compact
          ? itemExtent
          : widget.items.length * itemExtent + (widget.items.length - 1) * gap;
      return IosGlassSurface(
        blurEnabled: widget.blurEnabled,
        padding: const EdgeInsets.all(IosLikeTokens.space1),
        borderRadius: outerRadius,
        blur: compact ? 20 : 18,
        child: SizedBox(
          width: compact ? double.infinity : null,
          height: contentHeight,
          child: contents(
            itemExtent: itemExtent,
            step: step,
            contentHeight: contentHeight,
          ),
        ),
      );
    });
  }
}

class _SelectionSubstrate extends StatelessWidget {
  const _SelectionSubstrate({
    required this.radius,
    required this.color,
    required this.blur,
    required this.dragging,
  });

  final double radius;
  final Color color;
  final bool blur;
  final bool dragging;

  @override
  Widget build(BuildContext context) {
    final strength = ThemeController.instance.glassStrength.clamp(0.0, 1.0);
    final decoration = BoxDecoration(
      color: color.withValues(alpha: blur ? .10 + strength * .06 : .14),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: Colors.white.withValues(alpha: dragging ? .24 : .12),
      ),
      gradient: blur
          ? LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: dragging ? .14 : .08),
                color.withValues(alpha: .08 + strength * .04),
              ],
            )
          : null,
    );
    final surface = DecoratedBox(
      decoration: decoration,
      child: const SizedBox.expand(),
    );
    if (!blur) return surface;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: dragging ? 10 : 5,
          sigmaY: dragging ? 10 : 5,
        ),
        child: surface,
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.item,
    required this.selected,
    required this.compact,
    required this.reduceMotion,
    required this.selectedColor,
    required this.onTap,
  });

  final ({IconData icon, String label}) item;
  final bool selected;
  final bool compact;
  final bool reduceMotion;
  final Color selectedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = Duration(
        milliseconds: reduceMotion
            ? 0
            : (240 / ThemeController.instance.transitionSpeed).round());
    final foreground =
        selected ? selectedColor : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: Tooltip(
        message: item.label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(IosLikeTokens.controlRadius),
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              constraints: BoxConstraints(minHeight: compact ? 58 : 60),
              padding: EdgeInsets.symmetric(
                horizontal:
                    compact ? IosLikeTokens.space2 : IosLikeTokens.space3,
                vertical: compact ? IosLikeTokens.space1 : IosLikeTokens.space2,
              ),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius:
                    BorderRadius.circular(IosLikeTokens.controlRadius),
              ),
              child: compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedScale(
                          scale: selected ? 1.04 : 1,
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          child: Icon(item.icon, size: 20, color: foreground),
                        ),
                        const SizedBox(height: 4),
                        AnimatedDefaultTextStyle(
                          duration: duration,
                          style: theme.textTheme.labelSmall!.copyWith(
                            color: foreground,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                          child: Text(
                            item.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedScale(
                          scale: selected ? 1.04 : 1,
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          child: Icon(item.icon, size: 21, color: foreground),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          item.label,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: foreground,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
