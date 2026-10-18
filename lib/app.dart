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
                  themeAnimationDuration: const Duration(milliseconds: 420),
                  themeAnimationCurve: Curves.easeInOutCubic,
                  home: const HomePage(),
                )),
      );
}
