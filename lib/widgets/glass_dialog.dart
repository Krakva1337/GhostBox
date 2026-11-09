import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../theme/theme_controller.dart';

/// A bounded, low-opacity glass surface for dialogs and modal content.
class GlassDialogSurface extends StatelessWidget {
  const GlassDialogSurface({
    super.key,
    required this.child,
    this.optimizedMode = false,
    this.glassStrength,
    this.radius = 24,
    this.sigma = 8,
    this.padding = EdgeInsets.zero,
    this.backgroundColor,
  });

  final Widget child;
  final bool optimizedMode;
  final double? glassStrength;
  final double radius;
  final double sigma;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;

  static final Map<int, ui.ImageFilter> _filters = <int, ui.ImageFilter>{};

  @override
  Widget build(BuildContext context) {
    final strength = (glassStrength ?? ThemeController.instance.glassStrength)
        .clamp(0.0, 1.0);
    final surfaceColor =
        backgroundColor ?? Theme.of(context).colorScheme.surface;
    final effectiveSigma = sigma.clamp(0, 8).round();
    final filter = _filters.putIfAbsent(
        effectiveSigma,
        () => ui.ImageFilter.blur(
            sigmaX: effectiveSigma.toDouble(),
            sigmaY: effectiveSigma.toDouble(),
            tileMode: TileMode.decal));
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: surfaceColor.withValues(
            alpha: optimizedMode ? .98 : .86 - strength * .20),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: .16)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 8))
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: optimizedMode
          ? surface
          : BackdropFilter(filter: filter, child: surface),
    );
  }
}

/// Glass-backed alert with the familiar title/content/actions API.
class GlassAlertDialog extends StatelessWidget {
  const GlassAlertDialog({
    super.key,
    this.icon,
    this.title,
    this.content,
    this.actions,
    this.backgroundColor,
    this.optimizedMode = false,
    this.glassStrength,
    this.scrollable = false,
    this.contentPadding,
    this.titlePadding,
    this.actionsPadding,
    this.insetPadding =
        const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
  });

  final Widget? icon;
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Color? backgroundColor;
  final bool optimizedMode;
  final double? glassStrength;
  final bool scrollable;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? titlePadding;
  final EdgeInsetsGeometry? actionsPadding;
  final EdgeInsets insetPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxWidth =
        (MediaQuery.sizeOf(context).width - insetPadding.horizontal)
            .clamp(0.0, 560.0);
    return Dialog(
      backgroundColor: Colors.transparent,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: insetPadding,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: GlassDialogSurface(
        optimizedMode: optimizedMode,
        glassStrength: glassStrength,
        backgroundColor: backgroundColor ?? theme.colorScheme.surface,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minWidth: maxWidth.clamp(0, 280), maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (icon != null || title != null)
                Padding(
                  padding:
                      titlePadding ?? const EdgeInsets.fromLTRB(24, 22, 20, 12),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (icon != null) ...[icon!, const SizedBox(width: 12)],
                        if (title != null)
                          Expanded(
                              child: DefaultTextStyle(
                                  style: theme.textTheme.titleLarge ??
                                      const TextStyle(fontSize: 20),
                                  child: title!)),
                      ]),
                ),
              if (content != null)
                Flexible(
                  fit: FlexFit.loose,
                  child: Padding(
                    padding: contentPadding ??
                        const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    child: scrollable
                        ? SingleChildScrollView(child: content)
                        : content!,
                  ),
                ),
              if (actions != null && actions!.isNotEmpty)
                Padding(
                  padding: actionsPadding ??
                      const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Wrap(
                      alignment: WrapAlignment.end,
                      runAlignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 4,
                      children: actions!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
