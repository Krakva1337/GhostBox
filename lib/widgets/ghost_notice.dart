import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A single, dismissible notice above the page content and bottom navigation.
class GhostNotice {
  GhostNotice._();

  static OverlayEntry? _active;
  static VoidCallback? _dismissActive;
  static bool _transitioning = false;
  static int _generation = 0;

  static void show(BuildContext context, String message,
      {bool error = false, IconData? icon}) {
    if (!context.mounted || message.trim().isEmpty) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    final generation = ++_generation;
    final replaceActive = _active != null;
    if (replaceActive) hide();
    final waitForExit = replaceActive || _transitioning;
    if (waitForExit) {
      _transitioning = true;
      final delay = MediaQuery.maybeOf(context)?.disableAnimations == true
          ? Duration.zero
          : const Duration(milliseconds: 330);
      unawaited(Future<void>.delayed(delay, () {
        if (generation != _generation) return;
        _transitioning = false;
        if (context.mounted) {
          _insert(overlay, themes, context, message, error, icon);
        }
      }));
      return;
    }
    _insert(overlay, themes, context, message, error, icon);
  }

  static void _insert(OverlayState overlay, CapturedThemes themes,
      BuildContext context, String message, bool error, IconData? icon) {
    final key = GlobalKey<_NoticeState>();
    var removed = false;
    late final OverlayEntry entry;
    void removeEntry() {
      if (removed) return;
      removed = true;
      if (identical(_active, entry)) {
        _active = null;
        _dismissActive = null;
      }
      entry.remove();
      entry.dispose();
    }

    entry = OverlayEntry(
      builder: (overlayContext) => themes.wrap(
        _Notice(
          key: key,
          message: message,
          error: error,
          icon: icon,
          onDismissed: removeEntry,
        ),
      ),
    );
    _active = entry;
    _dismissActive = () {
      final state = key.currentState;
      if (state == null) {
        removeEntry();
      } else {
        state.dismiss();
      }
    };
    overlay.insert(entry);
  }

  /// Removes the current notice, including its animation and dismissal timer.
  static void hide() {
    final entry = _active;
    final dismiss = _dismissActive;
    _active = null;
    _dismissActive = null;
    if (entry == null) return;
    _transitioning = true;
    Timer(const Duration(milliseconds: 330), () {
      if (_active == null) _transitioning = false;
    });
    if (dismiss != null) {
      dismiss();
    } else {
      entry.remove();
      entry.dispose();
    }
  }
}

class _Notice extends StatefulWidget {
  const _Notice({
    super.key,
    required this.message,
    required this.error,
    required this.icon,
    required this.onDismissed,
  });

  final String message;
  final bool error;
  final IconData? icon;
  final VoidCallback onDismissed;

  @override
  State<_Notice> createState() => _NoticeState();
}

class _NoticeState extends State<_Notice> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;
  Timer? _timer;
  bool _closing = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 320),
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final media = MediaQuery.of(context);
    if (media.disableAnimations) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
    // Screen reader users control dismissal themselves. Longer messages remain
    // readable without a fixed short snackbar timeout.
    if (!media.accessibleNavigation) {
      final seconds = math.min(
          30,
          math.max(
              widget.error ? 9 : 6, (widget.message.runes.length / 14).ceil()));
      _timer = Timer(Duration(seconds: seconds), _dismiss);
    }
  }

  Future<void> _dismiss() async {
    if (_closing || !mounted) return;
    _closing = true;
    _timer?.cancel();
    if (!MediaQuery.of(context).disableAnimations) {
      try {
        await _controller.reverse().orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (mounted) widget.onDismissed();
  }

  void dismiss() => _dismiss();

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = widget.error ? colors.error : colors.primary;
    return Positioned(
      left: 16,
      right: 16,
      top: MediaQuery.of(context).padding.top + 16,
      child: Align(
        alignment: Alignment.topCenter,
        child: FadeTransition(
          opacity: _animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -.16),
              end: Offset.zero,
            ).animate(_animation),
            child: ScaleTransition(
                scale: Tween<double>(begin: .97, end: 1).animate(_animation),
                child: Semantics(
                  liveRegion: true,
                  container: true,
                  child: Material(
                    color: Color.alphaBlend(
                      accent.withValues(alpha: .05),
                      colors.surface,
                    ),
                    elevation: 16,
                    shadowColor: Colors.black.withValues(alpha: .35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                      side: BorderSide(color: accent.withValues(alpha: .25)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 480,
                        maxHeight: MediaQuery.sizeOf(context).height * .42,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 17, 12, 16),
                            child: Icon(
                              widget.icon ??
                                  (widget.error
                                      ? Icons.warning_amber_rounded
                                      : Icons.check_circle_outline_rounded),
                              color: accent,
                              size: 21,
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(vertical: 17),
                              child: Text(
                                widget.message,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.onSurface,
                                  fontSize: 13,
                                  height: 1.45,
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 4, right: 4),
                            child: IconButton(
                              onPressed: _dismiss,
                              tooltip: 'Закрыть уведомление',
                              iconSize: 18,
                              color: colors.onSurfaceVariant,
                              icon: const Icon(Icons.close),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )),
          ),
        ),
      ),
    );
  }
}
