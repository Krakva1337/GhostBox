import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme_controller.dart';

/// Compact toggle with a small thumb and a full-sized input target.
class GlassSwitch extends StatefulWidget {
  const GlassSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<GlassSwitch> createState() => _GlassSwitchState();
}

class _GlassSwitchState extends State<GlassSwitch> {
  bool _focused = false;
  bool _hovered = false;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appearance = ThemeController.instance;
    final enabled = widget.onChanged != null;
    final minimal = appearance.isIosLike;
    final accent = theme.colorScheme.primary;
    final muted = theme.colorScheme.onSurfaceVariant;
    final reduceMotion =
        appearance.reduceMotion || MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : Duration(milliseconds: (180 / appearance.transitionSpeed).round());
    final track = widget.value
        ? accent.withValues(alpha: enabled ? .86 : .36)
        : muted.withValues(alpha: enabled ? .22 : .12);

    return Semantics(
      toggled: widget.value,
      enabled: enabled,
      onTap: enabled ? _toggle : null,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            if (enabled) _toggle();
            return null;
          }),
        },
        child: ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? _toggle : null,
            onHorizontalDragUpdate: enabled
                ? (details) {
                    final next = details.localPosition.dx >= 29;
                    if (next != widget.value) widget.onChanged!(next);
                  }
                : null,
            onHorizontalDragEnd: enabled
                ? (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity.abs() > 80) {
                      widget.onChanged!(velocity > 0);
                    }
                  }
                : null,
            child: SizedBox(
              width: 52,
              height: 44,
              child: Align(
                alignment: Alignment.centerRight,
                child: AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  width: 46,
                  height: 27,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: track,
                    gradient: minimal
                        ? null
                        : LinearGradient(colors: [
                            Color.alphaBlend(
                                Colors.white.withValues(alpha: .08), track),
                            track,
                          ]),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _focused
                          ? accent
                          : muted.withValues(alpha: _hovered ? .4 : .14),
                      width: _focused ? 1.5 : 1,
                    ),
                  ),
                  child: AnimatedAlign(
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    alignment: widget.value
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      width: 15,
                      height: 15,
                      decoration: BoxDecoration(
                        color: enabled ? Colors.white : Colors.white60,
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x22000000),
                            blurRadius: 3,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
