import 'package:flutter/material.dart';
import 'features/home/home_page.dart';
import 'theme/theme_controller.dart';

class GhostBoxApp extends StatefulWidget {
  const GhostBoxApp({super.key});
  @override
  State<GhostBoxApp> createState() => _GhostBoxAppState();
}

class _GhostBoxAppState extends State<GhostBoxApp> {
  final controller = ThemeController.instance;
  @override
  void initState() {
    super.initState();
    controller.load();
  }

  @override
  Widget build(BuildContext context) => ThemeScope(
        controller: controller,
        child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => MaterialApp(
                  title: 'GhostBox',
                  debugShowCheckedModeBanner: false,
                  theme: controller.theme,
                  themeAnimationDuration: controller.reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 420),
                  themeAnimationCurve: Curves.easeInOutCubic,
                  builder: (context, child) {
                    final scale = controller.interfaceScale;
                    // Use the native view constraints directly at normal
                    // scale. Fitting the entire Navigator into another box
                    // adds an unnecessary full-window paint transform.
                    if (scale == 1) return child ?? const SizedBox.shrink();
                    final media = MediaQuery.of(context);
                    return LayoutBuilder(builder: (context, bounds) {
                      final size = Size(
                          bounds.maxWidth / scale, bounds.maxHeight / scale);
                      return ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          minWidth: size.width,
                          maxWidth: size.width,
                          minHeight: size.height,
                          maxHeight: size.height,
                          child: Transform.scale(
                            alignment: Alignment.topLeft,
                            scale: scale,
                            child: MediaQuery(
                              data: media.copyWith(
                                size: size,
                                devicePixelRatio:
                                    media.devicePixelRatio * scale,
                                padding: media.padding / scale,
                                viewPadding: media.viewPadding / scale,
                                viewInsets: media.viewInsets / scale,
                              ),
                              child: child ?? const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      );
                    });
                  },
                  home: const HomePage(),
                )),
      );
}
