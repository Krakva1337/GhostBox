import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'brand_icon.dart';
import 'theme_controller.dart';

class ThemeSettingsPanel extends StatefulWidget {
  const ThemeSettingsPanel({super.key, this.english = false});
  final bool english;

  @override
  State<ThemeSettingsPanel> createState() => _ThemeSettingsPanelState();
}

class _ThemeSettingsPanelState extends State<ThemeSettingsPanel> {
  final ScrollController _presetScroll = ScrollController();

  @override
  void dispose() {
    _presetScroll.dispose();
    super.dispose();
  }

  String _s(String ru, String en) => widget.english ? en : ru;

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

  @override
  Widget build(BuildContext context) {
    final controller = ThemeScope.of(context);
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_s('Оформление', 'Appearance'), style: theme.textTheme.titleMedium),
      const SizedBox(height: 6),
      Text(
          _s('Тёмные и светлые темы с настраиваемым акцентом.',
              'Dark and light themes with a custom accent.'),
          style: theme.textTheme.bodySmall),
      const SizedBox(height: 16),
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
                  height: 82,
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
      Text(_s('Значок приложения', 'App icon'),
          style: theme.textTheme.titleMedium),
      const SizedBox(height: 5),
      Text(
          _s('Независима от темы. Готовые значки меняют иконку приложения; своя палитра применяется в интерфейсе и на десктопе.',
              'Independent from the app theme. Presets change the app icon; custom colors apply in the UI and on desktop.'),
          style: theme.textTheme.bodySmall),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, bounds) {
        const spacing = 9.0;
        const minTileWidth = 56.0;
        final columns = ((bounds.maxWidth + spacing) / (minTileWidth + spacing))
            .floor()
            .clamp(1, _iconOptions.length + 1);
        final tileWidth = (bounds.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final icon in _iconOptions)
              SizedBox(
                  width: tileWidth,
                  child: _iconOption(context, controller, icon.$1,
                      _presetName(icon.$2), icon.$3, icon.$4)),
            SizedBox(
                width: tileWidth,
                child: _iconOption(
                    context,
                    controller,
                    'custom',
                    _s('Своя', 'Custom'),
                    controller.iconForeground,
                    controller.iconBackground)),
          ],
        );
      }),
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
                      onSelected: (color) =>
                          controller.setCustomIconColors(foreground: color),
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
                      onSelected: (color) =>
                          controller.setCustomIconColors(background: color),
                      trailing: _customIconColor(context, controller,
                          foreground: false),
                    ),
                  ],
                ),
              ),
      ),
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
                      ]),
                )),
    ]);
  }

  static const _iconOptions = <(String, String, Color, Color)>[
    ('classic', 'Классика', Color(0xFFD9D9D9), Color(0xFF10101B)),
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
        onTap: () => controller.setIconVariant(id),
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
          await controller.setCustomIconColors(
              foreground: foreground ? color : null,
              background: foreground ? null : color);
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
