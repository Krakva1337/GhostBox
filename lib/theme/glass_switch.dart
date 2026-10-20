import 'package:flutter/material.dart';

/// Shared compact glass toggle used by settings and the appearance panel.
class GlassSwitch extends StatelessWidget {
  const GlassSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final accent = Theme.of(context).colorScheme.primary;
    final surface = Theme.of(context).colorScheme.surface;

    void toggle() {
      if (enabled) onChanged!(!value);
    }

    return Semantics(
      button: true,
      toggled: value,
      enabled: enabled,
      onTap: enabled ? toggle : null,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? toggle : null,
          onHorizontalDragUpdate: enabled
              ? (details) {
                  // Let the thumb follow a deliberate drag in either
                  // direction, even when the gesture is slow.
                  final nextValue = details.localPosition.dx >= 26;
                  if (nextValue != value) onChanged!(nextValue);
                }
              : null,
          onHorizontalDragEnd: enabled
              ? (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity.abs() > 80) onChanged!(velocity > 0);
                }
              : null,
          child: SizedBox(
            width: 52,
            height: 40,
            child: Align(
              alignment: Alignment.centerRight,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 210),
                curve: Curves.easeOutCubic,
                width: 46,
                height: 27,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: value
                      ? accent.withValues(alpha: .66)
                      : Colors.white.withValues(alpha: .09),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: value
                        ? [
                            accent.withValues(alpha: .82),
                            accent.withValues(alpha: .57),
                          ]
                        : [
                            Colors.white.withValues(alpha: .15),
                            surface.withValues(alpha: .24),
                          ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: value
                        ? accent.withValues(alpha: .78)
                        : Colors.white.withValues(alpha: .24),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: value
                          ? accent.withValues(alpha: .19)
                          : Colors.black.withValues(alpha: .10),
                      blurRadius: 9,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 210),
                  curve: Curves.easeOutBack,
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 170),
                    width: 19,
                    height: 19,
                    decoration: BoxDecoration(
                      color: enabled ? Colors.white : Colors.white70,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: accent.withValues(alpha: value ? .42 : .10),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .22),
                          blurRadius: 4,
                          offset: const Offset(0, 1.5),
                        ),
                        BoxShadow(
                          color: Colors.white.withValues(alpha: .6),
                          blurRadius: 1,
                          offset: const Offset(0, -.5),
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
    );
  }
}
