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
                    final media = MediaQuery.of(context);
                    return LayoutBuilder(builder: (context, bounds) {
                      final size = Size(
                          bounds.maxWidth / scale, bounds.maxHeight / scale);
                      return FittedBox(
                        fit: BoxFit.fill,
                        child: SizedBox(
                          width: size.width,
                          height: size.height,
                          child: MediaQuery(
                            data: media.copyWith(
                              size: size,
                              devicePixelRatio: media.devicePixelRatio * scale,
                              padding: media.padding / scale,
                              viewPadding: media.viewPadding / scale,
                              viewInsets: media.viewInsets / scale,
                            ),
                            child: child ?? const SizedBox.shrink(),
                          ),
                        ),
                      );
                    });
                  },
                  home: const HomePage(),
                )),
      );
}
