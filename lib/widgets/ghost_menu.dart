import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An action or choice in GhostBox's shared floating menu.
class GhostMenuEntry<T> {
  const GhostMenuEntry({
    required this.value,
    required this.label,
    this.icon,
    this.leading,
    this.subtitle,
    this.enabled = true,
    this.selected = false,
    this.highlightSelected = false,
    this.iconColor,
  });

  final T value;
  final String label;
  final IconData? icon;
  final Widget? leading;
  final String? subtitle;
  final bool enabled;
  final bool selected;
  final bool highlightSelected;
  final Color? iconColor;
}

class GhostMenuScope extends InheritedWidget {
  const GhostMenuScope({
    super.key,
    required this.blurEnabled,
    required this.reduceMotion,
    required super.child,
  });

  final bool blurEnabled;
  final bool reduceMotion;

  static GhostMenuScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GhostMenuScope>();

  @override
  bool updateShouldNotify(GhostMenuScope oldWidget) =>
      blurEnabled != oldWidget.blurEnabled ||
      reduceMotion != oldWidget.reduceMotion;
}

Future<T?> showGhostMenu<T>({
  required BuildContext context,
  required List<GhostMenuEntry<T>> entries,
  BuildContext? anchorContext,
  bool centerOnAnchor = false,
  bool? blurEnabled,
  bool? reduceMotion,
}) async {
  if (entries.isEmpty) return Future<T?>.value();
  final navigator = Navigator.of(context);
  final scope = GhostMenuScope.maybeOf(context);
  final overlay = navigator.overlay?.context.findRenderObject();
  final anchor = anchorContext?.findRenderObject();
  Rect? anchorRect;
  if (anchor is RenderBox && overlay is RenderBox && anchor.hasSize) {
    anchorRect =
        anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
  }
  final route = _GhostMenuRoute<T>(
    entries: List.unmodifiable(entries),
    anchor: anchorRect,
    centerOnAnchor: centerOnAnchor,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    blurEnabled: blurEnabled ?? scope?.blurEnabled ?? true,
    reduceMotion: reduceMotion ??
        scope?.reduceMotion ??
        MediaQuery.maybeOf(context)?.disableAnimations ??
        false,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  );
  final result = await navigator.push<T>(route);
  await route.completed;
  return result;
}

class GhostMenuButton<T> extends StatelessWidget {
  const GhostMenuButton({
    super.key,
    required this.entries,
    required this.onSelected,
    this.tooltip,
    this.icon,
    this.child,
    this.blurEnabled,
    this.reduceMotion,
    this.anchorContext,
    this.centerOnAnchor = false,
  });

  final List<GhostMenuEntry<T>> entries;
  final ValueChanged<T> onSelected;
  final String? tooltip;
  final Widget? icon;
  final Widget? child;
  final bool? blurEnabled;
  final bool? reduceMotion;
  final BuildContext? anchorContext;
  final bool centerOnAnchor;

  Future<void> _open(BuildContext context) async {
    final result = await showGhostMenu<T>(
      context: context,
      entries: entries,
      anchorContext: anchorContext ?? context,
      centerOnAnchor: centerOnAnchor,
      blurEnabled: blurEnabled,
      reduceMotion: reduceMotion,
    );
    if (context.mounted && result != null) onSelected(result);
  }

  @override
  Widget build(BuildContext context) => Builder(builder: (anchorContext) {
        if (child == null) {
          return IconButton(
            tooltip: tooltip,
            onPressed: entries.isEmpty ? null : () => _open(anchorContext),
            icon: icon ?? const Icon(Icons.more_horiz_rounded),
          );
        }
        final button = InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: entries.isEmpty ? null : () => _open(anchorContext),
          child: child,
        );
        return tooltip == null
            ? button
            : Tooltip(message: tooltip!, child: button);
      });
}

class _GhostMenuRoute<T> extends PopupRoute<T> {
  _GhostMenuRoute({
    required this.entries,
    required this.anchor,
    required this.centerOnAnchor,
    required this.themes,
    required this.blurEnabled,
    required this.reduceMotion,
    required this.barrierLabel,
  });

  final List<GhostMenuEntry<T>> entries;
  final Rect? anchor;
  final bool centerOnAnchor;
  final CapturedThemes themes;
  final bool blurEnabled;
  final bool reduceMotion;

  @override
  final String barrierLabel;
  @override
  Color get barrierColor => Colors.transparent;
  @override
  bool get barrierDismissible => true;
  @override
  Duration get transitionDuration =>
      Duration(milliseconds: reduceMotion ? 80 : 190);
  @override
  Duration get reverseTransitionDuration =>
      Duration(milliseconds: reduceMotion ? 70 : 140);

  void _dismiss([T? value]) {
    // The menu remains visible during its reverse animation. A second click
    // must not pop the page underneath after this route has already popped.
    if (isCurrent) navigator?.pop(value);
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return themes.wrap(
      Builder(builder: (context) {
        final media = MediaQuery.of(context);
        return LayoutBuilder(builder: (context, constraints) {
          final safe = Rect.fromLTRB(
            media.padding.left + 10,
            media.padding.top + 10,
            constraints.maxWidth - media.padding.right - 10,
            constraints.maxHeight -
                math.max(media.padding.bottom, media.viewInsets.bottom) -
                10,
          );
          final availableWidth = math.max(1.0, safe.width);
          final availableHeight = math.max(1.0, safe.height);
          final width =
              math.min(anchor == null ? 350.0 : 310.0, availableWidth);
          final height = 12.0 +
              entries.fold<double>(
                  0, (sum, entry) => sum + (entry.subtitle == null ? 48 : 58));
          final scale = math.min(1.0, availableHeight / height);
          final displayedWidth = width * scale;
          final displayedHeight = height * scale;
          final left = anchor == null
              ? safe.left + (availableWidth - displayedWidth) / 2
              : (centerOnAnchor
                      ? anchor!.center.dx - displayedWidth / 2
                      : anchor!.right - displayedWidth)
                  .clamp(
                      safe.left, safe.left + availableWidth - displayedWidth);
          final below = (anchor?.bottom ?? safe.top) + 6;
          final desiredTop = anchor == null
              ? safe.top + (availableHeight - displayedHeight) / 2
              : below + displayedHeight <= safe.bottom
                  ? below
                  : anchor!.top - displayedHeight - 6;
          final top = desiredTop.clamp(
              safe.top, safe.top + availableHeight - displayedHeight);
          return Stack(clipBehavior: Clip.none, children: [
            Positioned(
              left: left,
              top: top,
              width: displayedWidth,
              height: displayedHeight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: AnimatedBuilder(
                    animation: animation,
                    builder: (context, _) {
                      final progress = Curves.easeOutCubic
                          .transform(animation.value.clamp(0.0, 1.0));
                      return Transform.translate(
                        offset:
                            Offset(0, reduceMotion ? 0 : -5 * (1 - progress)),
                        child: Transform.scale(
                          scale: reduceMotion ? 1 : .97 + .03 * progress,
                          alignment: Alignment.topCenter,
                          child: _panel(context, progress),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ]);
        });
      }),
    );
  }

  Widget _panel(BuildContext context, double progress) {
    final colors = Theme.of(context).colorScheme;
    Widget panel = Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: blurEnabled ? .87 : 1),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.onSurface.withValues(alpha: .08)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
              SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
              SingleActivator(LogicalKeyboardKey.arrowUp):
                  PreviousFocusIntent(),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) {
                  _dismiss();
                  return null;
                }),
              },
              child: Focus(
                autofocus: true,
                skipTraversal: true,
                child: FocusTraversalGroup(
                  policy: ReadingOrderTraversalPolicy(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var index = 0; index < entries.length; index++)
                        _GhostMenuRow<T>(
                          entry: entries[index],
                          autofocus: false,
                          reduceMotion: reduceMotion,
                          onTap: () => _dismiss(entries[index].value),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Fade the contents inside the filter. Fading the filter itself creates
    // an offscreen layer and prevents it from sampling the page underneath.
    panel = Opacity(opacity: progress, child: panel);
    if (blurEnabled) {
      final blurSigma = math.min(10.0, 17 * progress).toDouble();
      panel = BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.decal,
        ),
        child: panel,
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(18), child: panel);
  }
}

class _GhostMenuRow<T> extends StatefulWidget {
  const _GhostMenuRow({
    required this.entry,
    required this.autofocus,
    required this.reduceMotion,
    required this.onTap,
  });

  final GhostMenuEntry<T> entry;
  final bool autofocus;
  final bool reduceMotion;
  final VoidCallback onTap;

  @override
  State<_GhostMenuRow<T>> createState() => _GhostMenuRowState<T>();
}

class _GhostMenuRowState<T> extends State<_GhostMenuRow<T>> {
  bool hovered = false;
  bool focused = false;
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final colors = Theme.of(context).colorScheme;
    final highlightedSelection = entry.selected && entry.highlightSelected;
    final foreground = entry.enabled
        ? highlightedSelection
            ? colors.primary
            : colors.onSurface
        : colors.onSurface.withValues(alpha: .38);
    final accent = entry.enabled
        ? entry.iconColor ?? colors.primary
        : colors.onSurface.withValues(alpha: .32);
    return Semantics(
      selected: entry.selected,
      button: true,
      enabled: entry.enabled,
      child: InkWell(
        autofocus: widget.autofocus,
        canRequestFocus: entry.enabled,
        onTap: entry.enabled ? widget.onTap : null,
        onHover: (value) => setState(() => hovered = value),
        onFocusChange: (value) => setState(() => focused = value),
        onHighlightChanged: (value) => setState(() => pressed = value),
        borderRadius: BorderRadius.circular(12),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        child: AnimatedContainer(
          duration: Duration(milliseconds: widget.reduceMotion ? 60 : 130),
          curve: Curves.easeOutCubic,
          height: entry.subtitle == null ? 48 : 58,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: colors.primary.withValues(
                alpha: !entry.enabled
                    ? 0
                    : highlightedSelection
                        ? pressed
                            ? .38
                            : .30
                        : pressed
                            ? .18
                            : hovered
                                ? .12
                                : focused
                                    ? .07
                                    : 0),
            border: highlightedSelection
                ? Border.all(color: colors.primary.withValues(alpha: .78))
                : null,
            boxShadow: highlightedSelection
                ? [
                    BoxShadow(
                      color: colors.primary.withValues(alpha: .14),
                      blurRadius: 12,
                      spreadRadius: -4,
                    ),
                  ]
                : null,
          ),
          child: Row(children: [
            if (entry.leading != null || entry.icon != null) ...[
              SizedBox(
                width: 20,
                height: 20,
                child: IconTheme(
                  data: IconThemeData(size: 18, color: accent),
                  child: entry.leading ?? Icon(entry.icon),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: foreground,
                          fontSize: 13,
                          fontWeight: highlightedSelection
                              ? FontWeight.w700
                              : FontWeight.w500,
                          height: 1.2)),
                  if (entry.subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(entry.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: foreground.withValues(alpha: .60),
                            fontSize: 10,
                            height: 1.2)),
                  ],
                ],
              ),
            ),
            if (entry.selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check_rounded, size: 17, color: accent),
            ],
          ]),
        ),
      ),
    );
  }
}
