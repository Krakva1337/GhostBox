import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'brand_icon.dart';

enum ThemePreset {
  midnight,
  graphite,
  ocean,
  emerald,
  amethyst,
  sapphire,
  ruby,
  lavender,
  forest,
  sand,
  daylight,
  paper,
  mist,
  aurora,
  obsidian,
  sunset,
  arctic,
  custom
}

class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final instance = ThemeController._();
  static const _iconChannel = MethodChannel('app.ghostbox.ghostbox/app_icon');
  ThemePreset _preset = ThemePreset.midnight;
  Color _customAccent = const Color(0xFF8BB9F4);
  Color _customBackground = const Color(0xFF080D16);
  String _iconVariant = 'aurora';
  Color _iconForeground = const Color(0xFF8BB9F4);
  Color _iconBackground = const Color(0xFF080D16);
  bool _loaded = false;
  ThemePreset get preset => _preset;
  Color get accent => switch (_preset) {
        ThemePreset.midnight => const Color(0xFF8BB9F4),
        ThemePreset.graphite => const Color(0xFFB6BDC9),
        ThemePreset.ocean => const Color(0xFF4DC9E8),
        ThemePreset.emerald => const Color(0xFF7CDDB6),
        ThemePreset.amethyst => const Color(0xFFB9A0FF),
        ThemePreset.sapphire => const Color(0xFF78A9FF),
        ThemePreset.ruby => const Color(0xFFFF8295),
        ThemePreset.lavender => const Color(0xFFC7B5FF),
        ThemePreset.forest => const Color(0xFF8BCF9B),
        ThemePreset.sand => const Color(0xFFE5BF8C),
        ThemePreset.daylight => const Color(0xFF355FBB),
        ThemePreset.paper => const Color(0xFF6857B8),
        ThemePreset.mist => const Color(0xFF347F8A),
        ThemePreset.aurora => const Color(0xFF53D6C2),
        ThemePreset.obsidian => const Color(0xFF90A4C3),
        ThemePreset.sunset => const Color(0xFFFF9568),
        ThemePreset.arctic => const Color(0xFF247D9B),
        ThemePreset.custom => _customAccent,
      };
  Color get background => switch (_preset) {
        ThemePreset.midnight => const Color(0xFF070D18),
        ThemePreset.graphite => const Color(0xFF0D0F13),
        ThemePreset.ocean => const Color(0xFF061522),
        ThemePreset.emerald => const Color(0xFF091812),
        ThemePreset.amethyst => const Color(0xFF120D20),
        ThemePreset.sapphire => const Color(0xFF091426),
        ThemePreset.ruby => const Color(0xFF1A1018),
        ThemePreset.lavender => const Color(0xFF171326),
        ThemePreset.forest => const Color(0xFF0D1B15),
        ThemePreset.sand => const Color(0xFF201A12),
        ThemePreset.daylight => const Color(0xFFF1F5FC),
        ThemePreset.paper => const Color(0xFFF6F2EB),
        ThemePreset.mist => const Color(0xFFEDF5F5),
        ThemePreset.aurora => const Color(0xFF071A20),
        ThemePreset.obsidian => const Color(0xFF111722),
        ThemePreset.sunset => const Color(0xFF20120F),
        ThemePreset.arctic => const Color(0xFFEAF5FA),
        ThemePreset.custom => _customBackground,
      };
  Brightness get brightness => switch (_preset) {
        ThemePreset.daylight ||
        ThemePreset.paper ||
        ThemePreset.mist ||
        ThemePreset.arctic =>
          Brightness.light,
        ThemePreset.custom => _customBackground.computeLuminance() > .42
            ? Brightness.light
            : Brightness.dark,
        _ => Brightness.dark,
      };
  Color get foreground => brightness == Brightness.dark
      ? const Color(0xFFE8ECF4)
      : const Color(0xFF172033);
  Color get surface =>
      Color.alphaBlend(Colors.white.withValues(alpha: .045), background);
  Color get muted => brightness == Brightness.dark
      ? const Color(0xFF929DAD)
      : const Color(0xFF596477);
  Color get customAccent => _customAccent;
  Color get customBackground => _customBackground;
  String get iconVariant => _iconVariant;
  Color get iconForeground => _iconForeground;
  Color get iconBackground => _iconBackground;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('appearance.preset');
    _preset = ThemePreset.values.where((p) => p.name == name).firstOrNull ??
        ThemePreset.midnight;
    _customAccent =
        Color(prefs.getInt('appearance.accent') ?? _customAccent.toARGB32());
    _customBackground = Color(
        prefs.getInt('appearance.background') ?? _customBackground.toARGB32());
    final savedIcon = prefs.getString('appearance.iconVariant');
    // `classic` was the old launcher artwork. Migrate saved preferences so
    // existing installs stop restoring that icon after an app update.
    _iconVariant =
        savedIcon == null || savedIcon == 'classic' ? 'aurora' : savedIcon;
    if (savedIcon != _iconVariant) {
      await prefs.setString('appearance.iconVariant', _iconVariant);
    }
    _iconForeground = Color(prefs.getInt('appearance.iconForeground') ??
        _iconForeground.toARGB32());
    _iconBackground = Color(prefs.getInt('appearance.iconBackground') ??
        _iconBackground.toARGB32());
    await prefs.remove('appearance.glassMode');
    notifyListeners();
    await _applyPlatformIcon();
  }

  Future<void> setIconVariant(String value) async {
    _iconVariant = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appearance.iconVariant', value);
    await _applyPlatformIcon();
  }

  Future<void> setCustomIconColors(
      {Color? foreground, Color? background}) async {
    if (foreground != null) _iconForeground = foreground;
    if (background != null) _iconBackground = background;
    _iconVariant = 'custom';
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appearance.iconVariant', _iconVariant);
    await prefs.setInt('appearance.iconForeground', _iconForeground.toARGB32());
    await prefs.setInt('appearance.iconBackground', _iconBackground.toARGB32());
    await _applyPlatformIcon();
  }

  Future<bool> _applyPlatformIcon() async {
    try {
      final customPng = _iconVariant == 'custom'
          ? await renderCustomGhostIcon(_iconForeground, _iconBackground)
          : null;
      return await _iconChannel.invokeMethod<bool>('setAppIcon', {
            'variant': _iconVariant,
            'foreground': _iconForeground.toARGB32(),
            'background': _iconBackground.toARGB32(),
            if (customPng != null) 'customPng': customPng,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> select(ThemePreset value) async {
    _preset = value;
    notifyListeners();
    await _save();
  }

  Future<void> setCustom({Color? accent, Color? background}) async {
    if (accent != null) _customAccent = accent;
    if (background != null) _customBackground = background;
    _preset = ThemePreset.custom;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('appearance.preset', _preset.name);
    await prefs.setInt('appearance.accent', _customAccent.toARGB32());
    await prefs.setInt('appearance.background', _customBackground.toARGB32());
  }

  ThemeData get theme {
    final scheme =
        ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
            .copyWith(
      primary: accent,
      onPrimary: background,
      surface: surface,
      onSurface: foreground,
      onSurfaceVariant: muted,
      outline: (brightness == Brightness.dark ? Colors.white : Colors.black)
          .withValues(alpha: .14),
    );
    final base = ThemeData(
        useMaterial3: true,
        brightness: brightness,
        fontFamily: 'SF Pro Display',
        fontFamilyFallback: const [
          'SF Pro Text',
          '.AppleSystemUIFont',
          'Inter',
          'Roboto',
          'Arial'
        ],
        colorScheme: scheme,
        scaffoldBackgroundColor: background);
    final controlShape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(15));
    final controlOverlay = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.pressed)) {
        return accent.withValues(alpha: .18);
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return accent.withValues(alpha: .10);
      }
      return null;
    });
    final border = OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: scheme.outline));
    return base.copyWith(
      // Desktop popup menus use this color for the selected row. Keeping the
      // Material default produces a light gray rectangle in the dark UI.
      highlightColor: Colors.transparent,
      hoverColor: accent.withValues(alpha: .12),
      focusColor: accent.withValues(alpha: .16),
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontSize: 23, fontWeight: FontWeight.w700, letterSpacing: -.6),
        titleLarge: base.textTheme.titleLarge?.copyWith(
            fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -.4),
        titleMedium: base.textTheme.titleMedium
            ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        bodyLarge:
            base.textTheme.bodyLarge?.copyWith(fontSize: 14, height: 1.5),
        bodyMedium:
            base.textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.45),
        bodySmall: base.textTheme.bodySmall
            ?.copyWith(fontSize: 11, height: 1.4, color: muted),
      ),
      inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: background,
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
              borderSide: BorderSide(color: accent, width: 1.4)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          hintStyle: TextStyle(fontSize: 13, color: muted),
          labelStyle: TextStyle(fontSize: 12, color: muted)),
      cardTheme: CardThemeData(
          color: surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: scheme.outline.withValues(alpha: .06)))),
      dialogTheme: DialogThemeData(
          backgroundColor: surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
      bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: surface,
          showDragHandle: true,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)))),
      popupMenuTheme: PopupMenuThemeData(
          color: surface.withValues(alpha: .91),
          elevation: 12,
          shadowColor: Colors.black.withValues(alpha: .28),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: scheme.outline.withValues(alpha: .055))),
          textStyle: TextStyle(fontSize: 13, color: scheme.onSurface)),
      textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
              shape: WidgetStatePropertyAll(controlShape),
              overlayColor: controlOverlay)),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
              shape: WidgetStatePropertyAll(controlShape),
              overlayColor: controlOverlay)),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: ButtonStyle(
              shape: WidgetStatePropertyAll(controlShape),
              overlayColor: controlOverlay)),
      filledButtonTheme: FilledButtonThemeData(
          style: ButtonStyle(
              shape: WidgetStatePropertyAll(controlShape),
              overlayColor: controlOverlay)),
      iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
              shape: WidgetStatePropertyAll(controlShape),
              overlayColor: controlOverlay)),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accent.withValues(alpha: .92);
          }
          return muted.withValues(alpha: .28);
        }),
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : foreground),
        trackOutlineColor:
            WidgetStatePropertyAll(foreground.withValues(alpha: .12)),
        trackOutlineWidth: const WidgetStatePropertyAll(.5),
        splashRadius: 20,
      ),
      sliderTheme: base.sliderTheme.copyWith(
          activeTrackColor: accent,
          thumbColor: accent,
          overlayColor: accent.withValues(alpha: .08),
          trackHeight: 4),
      scrollbarTheme: ScrollbarThemeData(
          thickness: const WidgetStatePropertyAll(3),
          radius: const Radius.circular(10),
          crossAxisMargin: 4,
          mainAxisMargin: 5,
          thumbColor: WidgetStatePropertyAll(accent.withValues(alpha: .45))),
      snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: surface,
          contentTextStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      }),
    );
  }
}

class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope(
      {super.key, required ThemeController controller, required super.child})
      : super(notifier: controller);
  static ThemeController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>()!.notifier!;
}
