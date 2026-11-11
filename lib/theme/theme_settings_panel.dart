import 'dart:io';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'brand_icon.dart';
import 'theme_controller.dart';
import 'glass_switch.dart';

enum _IconChangeChoice { cancel, later, restart }

class ThemeSettingsPanel extends StatefulWidget {
  const ThemeSettingsPanel({super.key, this.english = false});
  final bool english;

  @override
  State<ThemeSettingsPanel> createState() => _ThemeSettingsPanelState();
}

class _ThemeSettingsPanelState extends State<ThemeSettingsPanel> {
  final ScrollController _presetScroll = ScrollController();
  final ScrollController _iconScroll = ScrollController();

  @override
  void dispose() {
    _presetScroll.dispose();
    _iconScroll.dispose();
    super.dispose();
  }

  String _s(String ru, String en) => widget.english ? en : ru;

  Future<void> _changeIcon(
    ThemeController controller, {
    required String variant,
    required String name,
    required Color foreground,
    required Color background,
    required Future<bool> Function(bool applyPlatform) update,
  }) async {
    if (controller.iconVariant == variant &&
        (variant != 'custom' ||
            (controller.iconForeground == foreground &&
                controller.iconBackground == background))) {
      return;
    }
    final _IconChangeChoice? choice;
    if (Platform.isAndroid) {
      choice = controller.androidIconApplyPending
          ? _IconChangeChoice.later
          : await showDialog<_IconChangeChoice>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: Text(
                    _s('Сменить иконку приложения?', 'Change the app icon?')),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GhostBoxBrandIcon(
                      variant: variant,
                      size: 56,
                      foreground: foreground,
                      background: background,
                    ),
                    const SizedBox(height: 14),
                    Text(_s(
                      'Чтобы применить значок «$name», GhostBox нужно перезапустить. Можно сделать это сейчас или при следующем запуске.',
                      'GhostBox needs to restart to apply the “$name” icon. You can do it now or the next time the app starts.',
                    )),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, _IconChangeChoice.cancel),
                    child: Text(_s('Отмена', 'Cancel')),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, _IconChangeChoice.later),
                    child: Text(_s('Напомнить позже', 'Remind me later')),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext, _IconChangeChoice.restart),
                    child: Text(_s('Перезапустить', 'Restart now')),
                  ),
                ],
              ),
            );
      if (choice == null || choice == _IconChangeChoice.cancel) return;
    } else {
      choice = _IconChangeChoice.restart;
    }

    final applyNow = choice == _IconChangeChoice.restart;
    final applied = await update(applyNow);
    if (!mounted) return;
    if (!Platform.isAndroid) return;

    if (!applyNow) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_s(
          'Иконка применится при следующем запуске GhostBox.',
          'The icon will be applied the next time GhostBox starts.',
        )),
      ));
      return;
    }
    if (!applied) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_s(
          'Не удалось применить иконку. GhostBox попробует снова при следующем запуске.',
          'Could not apply the icon. GhostBox will retry next time it starts.',
        )),
      ));
      return;
    }
    final restartScheduled = await controller.restartApplication();
    if (!mounted || restartScheduled) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(_s(
        'Иконка изменена. Закройте и снова откройте GhostBox, чтобы перезапустить приложение.',
        'The icon changed. Close and reopen GhostBox to restart the app.',
      )),
    ));
  }

  String _presetName(String value) => switch (value) {
        'Полночь' => _s('Полночь', 'Midnight'),
        'Графит' => _s('Графит', 'Graphite'),
        'Океан' => _s('Океан', 'Ocean'),
        'Изумруд' => _s('Изумруд', 'Emerald'),
        'Аметист' => _s('Аметист', 'Amethyst'),
        'Сапфир' => _s('Сапфир', 'Sapphire'),
        'Рубин' => _s('Рубин', 'Ruby'),
        'Лаванда' => _s('Лаванда', 'Lavender'),
        'Лес' => _s('Лес', 'Forest'),
        'Песок' => _s('Песок', 'Sand'),
        'Светлая' => _s('Светлая', 'Daylight'),
        'Бумага' => _s('Бумага', 'Paper'),
        'Туман' => _s('Туман', 'Mist'),
        'Аврора' => _s('Аврора', 'Aurora'),
        'Обсидиан' => _s('Обсидиан', 'Obsidian'),
        'Закат' => _s('Закат', 'Sunset'),
        'Арктика' => _s('Арктика', 'Arctic'),
        'Классика' => _s('Классика', 'Classic'),
        'Своя' => _s('Своя', 'Custom'),
        _ => value,
      };

  bool _importing = false;
  Future<void> _importFile(bool font) async {
    setState(() => _importing = true);
    try {
      String? name;
      Uint8List? bytes;
      if (Platform.isAndroid) {
        final result = await const MethodChannel('app.ghostbox.ghostbox/vpn')
            .invokeMapMethod<String, dynamic>(
                'pickAppearanceFile', {'kind': font ? 'font' : 'background'});
        name = result?['name'] as String?;
        bytes = result?['bytes'] as Uint8List?;
      } else {
        final file = await openFile(acceptedTypeGroups: [
          XTypeGroup(
            label: font ? 'Font' : 'Image',
            extensions: font ? ['ttf', 'otf'] : ['png', 'jpg', 'jpeg', 'webp'],
            uniformTypeIdentifiers: font ? ['public.font'] : ['public.image'],
          )
        ]);
        if (file == null) return;
        if (await file.length() > (font ? 5 : 12) * 1024 * 1024)
          throw const FormatException('File is too large');
        name = file.name;
        bytes = await file.readAsBytes();
      }
      if (name != null && bytes != null)
        await ThemeController.instance
            .importAppearanceFile(name, bytes, font: font);
    } on Object catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '${_s('Не удалось импортировать', 'Import failed')}: $error')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Widget _appearanceToggle({
    required Widget title,
    Widget? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    EdgeInsetsGeometry? contentPadding,
  }) =>
      MergeSemantics(
        child: ListTile(
          contentPadding: contentPadding,
          title: title,
          subtitle: subtitle,
          onTap: () => onChanged(!value),
          trailing: GlassSwitch(value: value, onChanged: onChanged),
        ),
      );

  Widget _animatedValue(String value) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: .92, end: 1).animate(animation),
            child: child,
          ),
        ),
        child: Container(
          key: ValueKey(value),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: .55),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(value,
              style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ),
      );

  Widget _animatedSlider({
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
  }) =>
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 4,
          thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 9, pressedElevation: 3),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 17),
        ),
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: onChanged,
        ),
      );

  Widget _transitionPreview(String style) {
    final details = switch (style) {
      'smooth' => (
          _s('Плавно затухает', 'Fades smoothly'),
          Icons.blur_on_rounded,
          Curves.easeInOutCubic,
        ),
      'spring' => (
          _s('Мягко пружинит', 'Bounces softly'),
          Icons.animation_rounded,
          Curves.easeOutBack,
        ),
      _ => (
          _s('Спокойное движение', 'Calm movement'),
          Icons.motion_photos_on_rounded,
          Curves.easeOutCubic,
        ),
    };
    final accent = Theme.of(context).colorScheme.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: details.$3,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: .16)),
      ),
      child: TweenAnimationBuilder<double>(
        key: ValueKey(style),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 320),
        curve: details.$3,
        builder: (context, progress, child) => Opacity(
          opacity: progress.clamp(0, 1),
          child: Transform.translate(
            offset: Offset((1 - progress) * 12, 0),
            child: child,
          ),
        ),
        child: Row(children: [
          Icon(details.$2, size: 17, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child:
                Text(details.$1, style: Theme.of(context).textTheme.bodySmall),
          ),
          Icon(Icons.circle,
              size: 8 + (style == 'spring' ? 2 : 0), color: accent),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ThemeScope.of(context);
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_s('Оформление', 'Appearance'), style: theme.textTheme.titleMedium),
      const SizedBox(height: 16),
      Text(_s('Режим интерфейса', 'Interface style'),
          style: theme.textTheme.titleSmall),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<InterfaceStyle>(
          segments: [
            ButtonSegment(
                value: InterfaceStyle.standard,
                icon: const Icon(Icons.dashboard_outlined, size: 18),
                label: Text(_s('Стандартный', 'Standard'))),
            const ButtonSegment(
                value: InterfaceStyle.iosLike,
                icon: Icon(Icons.layers_outlined, size: 18),
                label: Text('iOS-Like')),
          ],
          selected: {controller.interfaceStyle},
          onSelectionChanged: (value) =>
              controller.setInterfaceStyle(value.first),
        ),
      ),
      const SizedBox(height: 8),
      Text(
          controller.isIosLike
              ? _s(
                  'Liquid Glass, чистая типографика и мягкое движение. Светлый и тёмный вид настраиваются отдельно.',
                  'Liquid Glass, clean typography and gentle motion. Light and dark appearances are set independently.')
              : _s(
                  'Классический интерфейс GhostBox с вашими настройками оформления.',
                  'The classic GhostBox interface with your appearance settings.'),
          style: theme.textTheme.bodySmall),
      const SizedBox(height: 20),
      if (!controller.isIosLike) ...[
        Text(_s('Шрифт приложения', 'App font'),
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 7),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final font in ThemeController.availableFonts)
            ChoiceChip(
              label: Text(
                  font.$1 == 'SF Pro Display'
                      ? _s('Системный', 'System')
                      : font.$2,
                  style: TextStyle(fontFamily: font.$1)),
              selected: controller.selectedFontFamily == font.$1 &&
                  controller.customFontName == null,
              onSelected: (_) async {
                if (controller.customFontName != null) {
                  await controller.clearAppearanceFile(font: true);
                }
                await controller.setFontFamily(font.$1);
              },
            ),
        ]),
      ],
      const SizedBox(height: 10),
      if (!controller.isIosLike) ...[
        Text(_s('Эффект фона', 'Background effect'),
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 7),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final effect in ThemeController.backgroundEffects)
            FilterChip(
              label: Text(widget.english
                  ? effect.$2.split(' / ').last
                  : effect.$2.split(' / ').first),
              selected: effect.$1 == 'none'
                  ? controller.activeBackgroundEffects.isEmpty
                  : controller.activeBackgroundEffects.contains(effect.$1),
              onSelected: (_) => controller.toggleBackgroundEffect(effect.$1),
            ),
        ]),
      ],
      const SizedBox(height: 12),
      if (!controller.isIosLike) ...[
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.font_download_outlined),
            title: Text(_s('Свой шрифт', 'Custom font')),
            subtitle: Text(controller.customFontName ?? 'TTF / OTF · ≤ 5 MB'),
            onTap: _importing ? null : () => _importFile(true),
            trailing: controller.customFontName == null
                ? const Icon(Icons.add)
                : IconButton(
                    tooltip: _s('Сбросить шрифт', 'Reset font'),
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        controller.clearAppearanceFile(font: true))),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.image_outlined),
            title: Text(_s('Картинка на фоне', 'Background image')),
            subtitle: Text(
                controller.backgroundImageName ?? 'PNG / JPG / WebP · ≤ 12 MB'),
            onTap: _importing ? null : () => _importFile(false),
            trailing: controller.backgroundImage == null
                ? const Icon(Icons.add)
                : IconButton(
                    tooltip: _s('Убрать картинку', 'Remove image'),
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        controller.clearAppearanceFile(font: false))),
        if (_importing) const LinearProgressIndicator(),
      ],
      _appearanceToggle(
          contentPadding: EdgeInsets.zero,
          title: Text(_s('Размытие движения', 'Motion blur')),
          subtitle: Text(_s('Лёгкое размытие при переходах',
              'Subtle blur during transitions')),
          value: controller.motionBlur,
          onChanged: (value) => controller.setGlass(motion: value)),
      if (controller.motionBlur) ...[
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(
              child:
                  Text(_s('Сила размытия движения', 'Motion blur strength'))),
          _animatedValue('${(controller.motionBlurStrength * 100).round()}%'),
        ]),
        _animatedSlider(
          value: controller.motionBlurStrength,
          min: 0,
          max: 1,
          divisions: 20,
          label: '${(controller.motionBlurStrength * 100).round()}%',
          onChanged: (value) => controller.setGlass(blurStrength: value),
        ),
      ],
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(_s('Больше стекла', 'More glass')),
        _animatedValue('${(controller.glassStrength * 100).round()}%'),
      ]),
      _animatedSlider(
        value: controller.glassStrength,
        min: 0,
        max: 1,
        divisions: 10,
        label: '${(controller.glassStrength * 100).round()}%',
        onChanged: (value) => controller.setGlass(strength: value),
      ),
      if (controller.glassStrength >= .9) ...[
        _appearanceToggle(
            contentPadding: EdgeInsets.zero,
            title: Text(_s('Стеклянные панели', 'Glass panels')),
            value: controller.glassPanelsEnabled,
            onChanged: (value) => controller.setGlass(panels: value)),
        _appearanceToggle(
            contentPadding: EdgeInsets.zero,
            title: Text(_s('Стеклянные кнопки', 'Glass buttons')),
            value: controller.glassButtonsEnabled,
            onChanged: (value) => controller.setGlass(buttons: value)),
        _appearanceToggle(
            contentPadding: EdgeInsets.zero,
            title: Text(_s('Круглый бегунок при перетягивании',
                'Round thumb while dragging')),
            value: controller.glassSliderThumbEnabled,
            onChanged: (value) => controller.setGlass(sliderThumb: value)),
      ],
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Expanded(child: Text(_s('Размер интерфейса', 'Interface size'))),
        _animatedValue('${(controller.interfaceScale * 100).round()}%'),
      ]),
      _animatedSlider(
        value: controller.interfaceScale,
        min: .75,
        max: 1.5,
        divisions: 15,
        label: '${(controller.interfaceScale * 100).round()}%',
        onChanged: controller.setInterfaceScale,
      ),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(_s('Скорость переходов', 'Transition speed')),
        _animatedValue('${controller.transitionSpeed.toStringAsFixed(2)}×'),
      ]),
      _animatedSlider(
        value: controller.transitionSpeed,
        min: .5,
        max: 1.5,
        divisions: 4,
        label: '${controller.transitionSpeed.toStringAsFixed(2)}×',
        onChanged: (value) => controller.setGlass(speed: value),
      ),
      Text(_s('Стиль перехода', 'Transition style')),
      SegmentedButton<String>(
        segments: [
          ButtonSegment(value: 'soft', label: Text(_s('Мягкий', 'Soft'))),
          ButtonSegment(value: 'smooth', label: Text(_s('Плавный', 'Smooth'))),
          ButtonSegment(value: 'spring', label: Text(_s('Упругий', 'Spring'))),
        ],
        selected: {controller.transitionStyle},
        onSelectionChanged: (values) =>
            controller.setGlass(style: values.first),
      ),
      const SizedBox(height: 8),
      _transitionPreview(controller.transitionStyle),
      const SizedBox(height: 6),
      if (controller.isIosLike) ...[
        const SizedBox(height: 16),
        Text(_s('Внешний вид', 'Appearance'),
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
                value: false,
                icon: const Icon(Icons.light_mode_outlined, size: 18),
                label: Text(_s('Светлый', 'Light'))),
            ButtonSegment(
                value: true,
                icon: const Icon(Icons.dark_mode_outlined, size: 18),
                label: Text(_s('Тёмный', 'Dark'))),
          ],
          selected: {controller.iosDarkMode},
          onSelectionChanged: (value) => controller.setIosDarkMode(value.first),
        ),
      ],
      ...[
        Text(
            controller.isIosLike
                ? _s('Акцент из выбранной темы',
                    'Accent from the selected theme')
                : _s('Тёмные и светлые темы с настраиваемым акцентом.',
                    'Dark and light themes with a custom accent.'),
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 14),
        ScrollConfiguration(
            behavior: const MaterialScrollBehavior().copyWith(dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            }),
            child: Listener(
                onPointerSignal: (signal) {
                  if (signal is! PointerScrollEvent ||
                      !_presetScroll.hasClients) {
                    return;
                  }
                  GestureBinding.instance.pointerSignalResolver.register(signal,
                      (_) {
                    if (!_presetScroll.hasClients) return;
                    final delta = signal.scrollDelta.dx != 0
                        ? signal.scrollDelta.dx
                        : signal.scrollDelta.dy;
                    _presetScroll.position.pointerScroll(delta);
                  });
                },
                child: SizedBox(
                    height: 112 *
                        MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
                    child: SingleChildScrollView(
                        controller: _presetScroll,
                        scrollDirection: Axis.horizontal,
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                  width: 88,
                                  child: _preset(
                                      context,
                                      controller,
                                      ThemePreset.midnight,
                                      _presetName('Полночь'),
                                      const Color(0xFF070D18),
                                      const Color(0xFF8BB9F4))),
                              const SizedBox(width: 8),
                              SizedBox(
                                  width: 88,
                                  child: _preset(
                                      context,
                                      controller,
                                      ThemePreset.graphite,
                                      _presetName('Графит'),
                                      const Color(0xFF0D0F13),
                                      const Color(0xFFB6BDC9))),
                              const SizedBox(width: 8),
                              SizedBox(
                                  width: 88,
                                  child: _preset(
                                      context,
                                      controller,
                                      ThemePreset.ocean,
                                      _presetName('Океан'),
                                      const Color(0xFF061522),
                                      const Color(0xFF4DC9E8))),
                              const SizedBox(width: 8),
                              SizedBox(
                                  width: 88,
                                  child: _preset(
                                      context,
                                      controller,
                                      ThemePreset.emerald,
                                      _presetName('Изумруд'),
                                      const Color(0xFF091812),
                                      const Color(0xFF7CDDB6))),
                              const SizedBox(width: 8),
                              SizedBox(
                                  width: 88,
                                  child: _preset(
                                      context,
                                      controller,
                                      ThemePreset.amethyst,
                                      _presetName('Аметист'),
                                      const Color(0xFF120D20),
                                      const Color(0xFFB9A0FF))),
                              const SizedBox(width: 8),
                              SizedBox(
                                  width: 88,
                                  child: _preset(
                                      context,
                                      controller,
                                      ThemePreset.sapphire,
                                      _presetName('Сапфир'),
                                      const Color(0xFF091426),
                                      const Color(0xFF78A9FF))),
                              const SizedBox(width: 8),
                              SizedBox(
                                  width: 88,
                                  child: _preset(
                                      context,
                                      controller,
                                      ThemePreset.ruby,
                                      _presetName('Рубин'),
                                      const Color(0xFF1A1018),
                                      const Color(0xFFFF8295))),
                              for (final entry in const [
                                (
                                  ThemePreset.lavender,
                                  'Лаванда',
                                  Color(0xFF171326),
                                  Color(0xFFC7B5FF)
                                ),
                                (
                                  ThemePreset.forest,
                                  'Лес',
                                  Color(0xFF0D1B15),
                                  Color(0xFF8BCF9B)
                                ),
                                (
                                  ThemePreset.sand,
                                  'Песок',
                                  Color(0xFF201A12),
                                  Color(0xFFE5BF8C)
                                ),
                                (
                                  ThemePreset.daylight,
                                  'Светлая',
                                  Color(0xFFF1F5FC),
                                  Color(0xFF355FBB)
                                ),
                                (
                                  ThemePreset.paper,
                                  'Бумага',
                                  Color(0xFFF6F2EB),
                                  Color(0xFF6857B8)
                                ),
                                (
                                  ThemePreset.mist,
                                  'Туман',
                                  Color(0xFFEDF5F5),
                                  Color(0xFF347F8A)
                                ),
                                (
                                  ThemePreset.aurora,
                                  'Аврора',
                                  Color(0xFF071A20),
                                  Color(0xFF53D6C2)
                                ),
                                (
                                  ThemePreset.obsidian,
                                  'Обсидиан',
                                  Color(0xFF111722),
                                  Color(0xFF90A4C3)
                                ),
                                (
                                  ThemePreset.sunset,
                                  'Закат',
                                  Color(0xFF20120F),
                                  Color(0xFFFF9568)
                                ),
                                (
                                  ThemePreset.arctic,
                                  'Арктика',
                                  Color(0xFFEAF5FA),
                                  Color(0xFF247D9B)
                                ),
                              ]) ...[
                                const SizedBox(width: 8),
                                SizedBox(
                                    width: 88,
                                    child: _preset(
                                        context,
                                        controller,
                                        entry.$1,
                                        _presetName(entry.$2),
                                        entry.$3,
                                        entry.$4)),
                              ],
                              const SizedBox(width: 8),
                              SizedBox(
                                  width: 88,
                                  child: _preset(
                                      context,
                                      controller,
                                      ThemePreset.custom,
                                      _presetName('Своя'),
                                      controller.customBackground,
                                      controller.customAccent)),
                            ]))))),
        const SizedBox(height: 12),
        SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
                onPressed: () => controller.select(ThemePreset.custom),
                icon: const Icon(Icons.palette_outlined, size: 18),
                label: Text(_s('Настроить свою тему', 'Customize theme')))),
        const SizedBox(height: 20),
      ],
      if (Platform.isMacOS) ...[
        const SizedBox(height: 20),
        Text(
            _s('Оформление значка приложения настраивается в macOS и соответствует выбранному режиму значков Dock.',
                'macOS controls the app icon appearance and applies the selected Dock icon mode.'),
            style: theme.textTheme.bodySmall),
      ] else ...[
        Text(_s('Значок приложения', 'App icon'),
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 5),
        Text(
            Platform.isAndroid
                ? _s(
                    'Готовые значки и своя палитра меняют иконку приложения.',
                    'Presets and custom colors change the app icon.',
                  )
                : _s(
                    'Готовые значки меняют иконку приложения; своя палитра применяется в интерфейсе и на десктопе.',
                    'Presets change the app icon; custom colors apply in the UI and on desktop.',
                  ),
            style: theme.textTheme.bodySmall),
        if (Platform.isAndroid && controller.androidIconApplyPending) ...[
          const SizedBox(height: 7),
          Text(
            _s('Новая иконка ожидает перезапуска приложения.',
                'The new icon is waiting for an app restart.'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
        const SizedBox(height: 12),
        ScrollConfiguration(
          behavior: const MaterialScrollBehavior().copyWith(dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
          }),
          child: Listener(
            onPointerSignal: (signal) {
              if (signal is! PointerScrollEvent || !_iconScroll.hasClients) {
                return;
              }
              GestureBinding.instance.pointerSignalResolver.register(signal,
                  (_) {
                if (!_iconScroll.hasClients) return;
                final delta = signal.scrollDelta.dx != 0
                    ? signal.scrollDelta.dx
                    : signal.scrollDelta.dy;
                _iconScroll.position.pointerScroll(delta);
              });
            },
            child: SizedBox(
              height: 82,
              child: SingleChildScrollView(
                controller: _iconScroll,
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final icon in _iconOptions) ...[
                      SizedBox(
                        width: 72,
                        child: _iconOption(context, controller, icon.$1,
                            _presetName(icon.$2), icon.$3, icon.$4),
                      ),
                      const SizedBox(width: 8),
                    ],
                    SizedBox(
                      width: 72,
                      child: _iconOption(
                        context,
                        controller,
                        'custom',
                        _s('Своя', 'Custom'),
                        controller.iconForeground,
                        controller.iconBackground,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeInOutCubic,
          child: controller.iconVariant != 'custom'
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s('Цвет призрака', 'Ghost color'),
                          style: theme.textTheme.bodySmall),
                      const SizedBox(height: 9),
                      _swatchPalette(
                        context,
                        colors: _iconColors,
                        selected: controller.iconForeground,
                        onSelected: (color) => _changeIcon(
                          controller,
                          variant: 'custom',
                          name: _s('Своя палитра', 'Custom palette'),
                          foreground: color,
                          background: controller.iconBackground,
                          update: (apply) => controller.setCustomIconColors(
                            foreground: color,
                            applyPlatform: apply,
                          ),
                        ),
                        trailing: _customIconColor(context, controller,
                            foreground: true),
                      ),
                      const SizedBox(height: 16),
                      Text(_s('Фон значка', 'Icon background'),
                          style: theme.textTheme.bodySmall),
                      const SizedBox(height: 9),
                      _swatchPalette(
                        context,
                        colors: _iconBackgrounds,
                        selected: controller.iconBackground,
                        onSelected: (color) => _changeIcon(
                          controller,
                          variant: 'custom',
                          name: _s('Своя палитра', 'Custom palette'),
                          foreground: controller.iconForeground,
                          background: color,
                          update: (apply) => controller.setCustomIconColors(
                            background: color,
                            applyPlatform: apply,
                          ),
                        ),
                        trailing: _customIconColor(context, controller,
                            foreground: false),
                      ),
                    ],
                  ),
                ),
        ),
      ],
      AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOutCubic,
          child: controller.preset != ThemePreset.custom
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_s('Цвет акцента', 'Accent color'),
                            style: theme.textTheme.bodySmall),
                        const SizedBox(height: 10),
                        _swatchPalette(
                          context,
                          colors: const [
                            Color(0xFF8BB9F4),
                            Color(0xFF9AA7FF),
                            Color(0xFF8DD4CB),
                            Color(0xFFE9B995),
                            Color(0xFFD6A4CA),
                            Color(0xFFB6BDC9),
                            Color(0xFF4DC9E8),
                            Color(0xFF7CDDB6),
                            Color(0xFFB9A0FF),
                            Color(0xFFFF7A9E),
                            Color(0xFFFFC857),
                            Color(0xFFEF6A5B),
                            Color(0xFF6FCE72),
                            Color(0xFF3E9BE8),
                            Color(0xFFDB6DD2),
                            Color(0xFFB6D947),
                            Color(0xFF42B8A6),
                            Color(0xFFFFA64D),
                          ],
                          selected: controller.accent,
                          onSelected: (color) =>
                              controller.setCustom(accent: color),
                          trailing: _customButton(
                              context,
                              _s('Свой акцент', 'Custom accent'),
                              controller.customAccent,
                              false),
                        ),
                        if (!controller.isIosLike) ...[
                          const SizedBox(height: 18),
                          Text(_s('Фон', 'Background'),
                              style: theme.textTheme.bodySmall),
                          const SizedBox(height: 10),
                          _swatchPalette(
                            context,
                            colors: const [
                              Color(0xFF05080F),
                              Color(0xFF0A1220),
                              Color(0xFF111318),
                              Color(0xFF15121C),
                              Color(0xFF061522),
                              Color(0xFF091812),
                              Color(0xFF120D20),
                              Color(0xFF081C2B),
                              Color(0xFF10172E),
                              Color(0xFF0D1B18),
                              Color(0xFF0C1020),
                              Color(0xFF151A2D),
                              Color(0xFF1A2130),
                              Color(0xFF1C1224),
                              Color(0xFF0C2023),
                              Color(0xFF241B12),
                              Color(0xFF20242B),
                              Color(0xFFF1F5FC),
                              Color(0xFFF6F2EB),
                              Color(0xFFEDF5F5),
                              Color(0xFFEAF5FA),
                              Color(0xFFF7EEF3),
                              Color(0xFFF2F4EA),
                              Color(0xFFECEFF6),
                              Color(0xFFFFF4E8),
                            ],
                            selected: controller.background,
                            onSelected: (color) =>
                                controller.setCustom(background: color),
                            trailing: _customButton(
                                context,
                                _s('Свой фон', 'Custom background'),
                                controller.customBackground,
                                true),
                          ),
                        ],
                      ]),
                )),
    ]);
  }

  static const _iconOptions = <(String, String, Color, Color)>[
    ('midnight', 'Полночь', Color(0xFF8BB9F4), Color(0xFF070612)),
    ('graphite', 'Графит', Color(0xFFB6BDC9), Color(0xFF0D0F13)),
    ('ocean', 'Океан', Color(0xFF4DC9E8), Color(0xFF061522)),
    ('emerald', 'Изумруд', Color(0xFF7CDDB6), Color(0xFF091812)),
    ('amethyst', 'Аметист', Color(0xFFB9A0FF), Color(0xFF120D20)),
    ('sapphire', 'Сапфир', Color(0xFF78A9FF), Color(0xFF091426)),
    ('ruby', 'Рубин', Color(0xFFFF8295), Color(0xFF1A1018)),
    ('lavender', 'Лаванда', Color(0xFFC7B5FF), Color(0xFF171326)),
    ('forest', 'Лес', Color(0xFF8BCF9B), Color(0xFF0D1B15)),
    ('sand', 'Песок', Color(0xFFE5BF8C), Color(0xFF201A12)),
    ('daylight', 'Светлая', Color(0xFF355FBB), Color(0xFFE8EEF8)),
    ('paper', 'Бумага', Color(0xFF6857B8), Color(0xFFF0EBE2)),
    ('mist', 'Туман', Color(0xFF347F8A), Color(0xFFE5EEEE)),
    ('aurora', 'Аврора', Color(0xFF53D6C2), Color(0xFF071A20)),
    ('obsidian', 'Обсидиан', Color(0xFF90A4C3), Color(0xFF111722)),
    ('sunset', 'Закат', Color(0xFFFF9568), Color(0xFF20120F)),
    ('arctic', 'Арктика', Color(0xFF247D9B), Color(0xFFE2F0F4)),
  ];

  static const _iconColors = [
    Color(0xFF8BB9F4),
    Color(0xFF4DC9E8),
    Color(0xFF7CDDB6),
    Color(0xFFB9A0FF),
    Color(0xFF78A9FF),
    Color(0xFFFF8295),
    Color(0xFFFF9568),
    Color(0xFFE5BF8C),
    Color(0xFFE8ECF4),
    Color(0xFF355FBB),
    Color(0xFF347F8A),
    Color(0xFF8BCF9B),
  ];

  static const _iconBackgrounds = [
    Color(0xFF070612),
    Color(0xFF0D0F13),
    Color(0xFF061522),
    Color(0xFF091812),
    Color(0xFF120D20),
    Color(0xFF1A1018),
    Color(0xFF201A12),
    Color(0xFF171326),
    Color(0xFFFFFFFF),
    Color(0xFFF1F5FC),
    Color(0xFFF6F2EB),
    Color(0xFFEAF5FA),
  ];

  Widget _iconOption(BuildContext context, ThemeController controller,
      String id, String name, Color foreground, Color background) {
    final selected = controller.iconVariant == id;
    return Tooltip(
      message: name,
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: () => _changeIcon(
          controller,
          variant: id,
          name: name,
          foreground: foreground,
          background: background,
          update: (apply) =>
              controller.setIconVariant(id, applyPlatform: apply),
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: 62,
          decoration: BoxDecoration(
            color: selected ? controller.accent.withValues(alpha: .12) : null,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected
                  ? controller.accent
                  : Theme.of(context).colorScheme.outline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GhostBoxBrandIcon(
                variant: id,
                size: 34,
                foreground: foreground,
                background: background,
              ),
              const SizedBox(height: 4),
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 8.5,
                      color: Theme.of(context).colorScheme.onSurface)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _customIconColor(BuildContext context, ThemeController controller,
      {required bool foreground}) {
    final label = foreground
        ? _s('Свой цвет призрака', 'Custom ghost color')
        : _s('Свой цвет фона', 'Custom background color');
    return IconButton.outlined(
      tooltip: label,
      icon: const Icon(Icons.colorize_rounded, size: 18),
      onPressed: () async {
        final color = await showDialog<Color>(
            context: context,
            builder: (_) => _ColorDialog(
                initial: foreground
                    ? controller.iconForeground
                    : controller.iconBackground,
                background: !foreground,
                english: widget.english));
        if (color != null) {
          await _changeIcon(
            controller,
            variant: 'custom',
            name: _s('Своя палитра', 'Custom palette'),
            foreground: foreground ? color : controller.iconForeground,
            background: foreground ? controller.iconBackground : color,
            update: (apply) => controller.setCustomIconColors(
              foreground: foreground ? color : null,
              background: foreground ? null : color,
              applyPlatform: apply,
            ),
          );
        }
      },
    );
  }

  Widget _preset(BuildContext context, ThemeController controller,
      ThemePreset preset, String name, Color background, Color accent) {
    final selected = controller.preset == preset;
    final displayName = !widget.english
        ? name
        : const {
              'Полночь': 'Midnight',
              'Графит': 'Graphite',
              'Океан': 'Ocean',
              'Изумруд': 'Emerald',
              'Аметист': 'Amethyst',
              'Сапфир': 'Sapphire',
              'Рубин': 'Ruby',
              'Лаванда': 'Lavender',
              'Лес': 'Forest',
              'Песок': 'Sand',
              'Светлая': 'Daylight',
              'Бумага': 'Paper',
              'Туман': 'Mist',
              'Аврора': 'Aurora',
              'Обсидиан': 'Obsidian',
              'Закат': 'Sunset',
              'Арктика': 'Arctic',
              'Своя': 'Custom',
            }[name] ??
            name;
    return Semantics(
        selected: selected,
        button: true,
        label: 'Theme $displayName',
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => controller.select(preset),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                    color: selected
                        ? controller.accent
                        : Colors.white.withValues(alpha: .1),
                    width: selected ? 1.5 : 1)),
            child: Column(children: [
              Container(
                  height: 26,
                  width: 26,
                  decoration: BoxDecoration(
                      color: accent.withValues(alpha: .18),
                      shape: BoxShape.circle),
                  child: Icon(Icons.circle, size: 10, color: accent)),
              const SizedBox(height: 10),
              Text(displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11,
                      color: background.computeLuminance() > .42
                          ? const Color(0xFF172033)
                          : const Color(0xFFE8ECF4),
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w400)),
            ]),
          ),
        ));
  }

  Widget _swatchPalette(
    BuildContext context, {
    required List<Color> colors,
    required Color selected,
    required ValueChanged<Color> onSelected,
    Widget? trailing,
  }) =>
      LayoutBuilder(builder: (context, bounds) {
        const spacing = 10.0;
        const minTileSize = 48.0;
        const maxTileSize = 58.0;
        final columns = ((bounds.maxWidth + spacing) / (minTileSize + spacing))
            .floor()
            .clamp(1, colors.length + (trailing == null ? 0 : 1));
        final tileSize = ((bounds.maxWidth - spacing * (columns - 1)) / columns)
            .clamp(minTileSize, maxTileSize)
            .toDouble();
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final color in colors)
              _swatch(
                context,
                color,
                selected,
                () => onSelected(color),
                size: tileSize,
              ),
            if (trailing != null)
              SizedBox(
                  width: tileSize,
                  height: tileSize,
                  child: Center(child: trailing)),
          ],
        );
      });

  Widget _swatch(
          BuildContext context, Color color, Color selected, VoidCallback onTap,
          {double size = 42}) =>
      Semantics(
        label: 'Цвет #${color.toARGB32().toRadixString(16).substring(2)}',
        selected: color == selected,
        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              height: size,
              width: size,
              decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: color == selected
                          ? Colors.white
                          : Colors.white.withValues(alpha: .15),
                      width: color == selected ? 2 : 1)),
              child: color == selected
                  ? Icon(Icons.circle,
                      size: 8,
                      color: color.computeLuminance() > .4
                          ? Colors.black
                          : Colors.white)
                  : null,
            )),
      );

  Widget _customButton(
          BuildContext context, String label, Color initial, bool background) =>
      IconButton.outlined(
        tooltip: label,
        icon: const Icon(Icons.colorize_rounded, size: 18),
        onPressed: () async {
          final controller = ThemeController.instance;
          final color = await showDialog<Color>(
              context: context,
              builder: (_) => _ColorDialog(
                  initial: initial,
                  background: background,
                  english: widget.english));
          if (color != null) {
            await controller.setCustom(
                accent: background ? null : color,
                background: background ? color : null);
          }
        },
      );
}

class _ColorDialog extends StatefulWidget {
  const _ColorDialog(
      {required this.initial, required this.background, required this.english});
  final Color initial;
  final bool background;
  final bool english;
  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  String _s(String ru, String en) => widget.english ? en : ru;
  late final TextEditingController input = TextEditingController(
      text: widget.initial
          .toARGB32()
          .toRadixString(16)
          .substring(2)
          .toUpperCase());
  String? error;

  List<Color> get _palette => widget.background
      ? const [
          Color(0xFF05080F),
          Color(0xFF0A1220),
          Color(0xFF111318),
          Color(0xFF15121C),
          Color(0xFF081C2B),
          Color(0xFF10172E),
          Color(0xFF18102A),
          Color(0xFF0D1B18),
          Color(0xFF0C1020),
          Color(0xFF151A2D),
          Color(0xFF1A2130),
          Color(0xFF1C1224),
          Color(0xFF0C2023),
          Color(0xFF241B12),
          Color(0xFF20242B),
          Color(0xFFF1F5FC),
          Color(0xFFF6F2EB),
          Color(0xFFEDF5F5),
          Color(0xFFEAF5FA),
          Color(0xFFF7EEF3),
          Color(0xFFF2F4EA),
          Color(0xFFECEFF6),
          Color(0xFFFFF4E8),
        ]
      : const [
          Color(0xFF73A9F4),
          Color(0xFF7788FF),
          Color(0xFF8DD4CB),
          Color(0xFFE9B995),
          Color(0xFFD6A4CA),
          Color(0xFFB6BDC9),
          Color(0xFFFF7A9E),
          Color(0xFFFFC857),
          Color(0xFF45D7C4),
          Color(0xFF9E8CFF),
          Color(0xFF7CB3FF),
          Color(0xFFC4E86B),
        ];

  String _hex(Color color) =>
      color.toARGB32().toRadixString(16).substring(2).toUpperCase();

  void _pick(Color color) => setState(() {
        input.text = _hex(color);
        error = null;
      });
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void submit() {
    final raw = input.text.trim().replaceFirst('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(raw)) {
      setState(() => error = _s('Введите 6 символов, например 8BB9F4',
          'Enter 6 characters, for example 8BB9F4'));
      return;
    }
    final color = Color(0xFF000000 | int.parse(raw, radix: 16));
    if (!widget.background && color.computeLuminance() < .25) {
      setState(() => error = _s('Выберите светлее, чтобы кнопки были читаемыми',
          'Choose a lighter color to keep buttons readable'));
      return;
    }
    Navigator.pop(context, color);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.background
            ? _s('Свой фон', 'Custom background')
            : _s('Свой акцент', 'Custom accent')),
        content: SizedBox(
          width: 320,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s('Палитра', 'Palette'),
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                Wrap(spacing: 9, runSpacing: 9, children: [
                  for (final color in _palette)
                    InkWell(
                      onTap: () => _pick(color),
                      borderRadius: BorderRadius.circular(13),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _hex(color) == input.text.toUpperCase()
                                ? Colors.white
                                : Colors.white.withValues(alpha: .2),
                            width:
                                _hex(color) == input.text.toUpperCase() ? 2 : 1,
                          ),
                        ),
                        child: _hex(color) == input.text.toUpperCase()
                            ? Icon(Icons.check_rounded,
                                size: 16,
                                color: color.computeLuminance() > .4
                                    ? Colors.black
                                    : Colors.white)
                            : null,
                      ),
                    ),
                ]),
                const SizedBox(height: 16),
                TextField(
                    controller: input,
                    autofocus: true,
                    maxLength: 7,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                        labelText: _s('Или введите HEX', 'Or enter HEX'),
                        hintText: '8BB9F4',
                        prefixText: '# ',
                        errorText: error,
                        errorMaxLines: 3),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => submit()),
              ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_s('Отмена', 'Cancel'))),
          FilledButton(onPressed: submit, child: Text(_s('Применить', 'Apply')))
        ],
      );
}
