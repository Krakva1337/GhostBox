import 'package:flutter/material.dart';
import 'theme_controller.dart';

class ThemeSettingsPanel extends StatelessWidget {
  const ThemeSettingsPanel({super.key, this.english = false});
  final bool english;
  String _s(String ru, String en) => english ? en : ru;

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
      SizedBox(
          height: 82,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            SizedBox(
                width: 88,
                child: _preset(
                    context,
                    controller,
                    ThemePreset.midnight,
                    'Полночь',
                    const Color(0xFF070D18),
                    const Color(0xFF8BB9F4))),
            const SizedBox(width: 8),
            SizedBox(
                width: 88,
                child: _preset(
                    context,
                    controller,
                    ThemePreset.graphite,
                    'Графит',
                    const Color(0xFF0D0F13),
                    const Color(0xFFB6BDC9))),
            const SizedBox(width: 8),
            SizedBox(
                width: 88,
                child: _preset(context, controller, ThemePreset.ocean, 'Океан',
                    const Color(0xFF061522), const Color(0xFF4DC9E8))),
            const SizedBox(width: 8),
            SizedBox(
                width: 88,
                child: _preset(
                    context,
                    controller,
                    ThemePreset.emerald,
                    'Изумруд',
                    const Color(0xFF091812),
                    const Color(0xFF7CDDB6))),
            const SizedBox(width: 8),
            SizedBox(
                width: 88,
                child: _preset(
                    context,
                    controller,
                    ThemePreset.amethyst,
                    'Аметист',
                    const Color(0xFF120D20),
                    const Color(0xFFB9A0FF))),
            const SizedBox(width: 8),
            SizedBox(
                width: 88,
                child: _preset(
                    context,
                    controller,
                    ThemePreset.sapphire,
                    'Сапфир',
                    const Color(0xFF091426),
                    const Color(0xFF78A9FF))),
            const SizedBox(width: 8),
            SizedBox(
                width: 88,
                child: _preset(context, controller, ThemePreset.ruby, 'Рубин',
                    const Color(0xFF1A1018), const Color(0xFFFF8295))),
            for (final entry in const [
              (
                ThemePreset.lavender,
                'Лаванда',
                Color(0xFF171326),
                Color(0xFFC7B5FF)
              ),
              (ThemePreset.forest, 'Лес', Color(0xFF0D1B15), Color(0xFF8BCF9B)),
              (ThemePreset.sand, 'Песок', Color(0xFF201A12), Color(0xFFE5BF8C)),
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
              (ThemePreset.mist, 'Туман', Color(0xFFEDF5F5), Color(0xFF347F8A)),
            ]) ...[
              const SizedBox(width: 8),
              SizedBox(
                  width: 88,
                  child: _preset(context, controller, entry.$1, entry.$2,
                      entry.$3, entry.$4)),
            ],
            const SizedBox(width: 8),
            SizedBox(
                width: 88,
                child: _preset(context, controller, ThemePreset.custom, 'Своя',
                    controller.customBackground, controller.customAccent)),
          ])),
      const SizedBox(height: 12),
      SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
              onPressed: () => controller.select(ThemePreset.custom),
              icon: const Icon(Icons.palette_outlined, size: 18),
              label: Text(_s('Настроить свою тему', 'Customize theme')))),
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
                        Wrap(spacing: 10, runSpacing: 10, children: [
                          for (final color in const [
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
                            Color(0xFF45D7C4),
                            Color(0xFFEF6A5B),
                            Color(0xFF6FCE72),
                            Color(0xFF3E9BE8),
                            Color(0xFFDB6DD2),
                            Color(0xFFB6D947),
                            Color(0xFF42B8A6),
                            Color(0xFFFFA64D)
                          ])
                            _swatch(context, color, controller.accent,
                                () => controller.setCustom(accent: color)),
                          _customButton(
                              context,
                              _s('Свой акцент', 'Custom accent'),
                              controller.customAccent,
                              false),
                        ]),
                        const SizedBox(height: 18),
                        Text(_s('Фон', 'Background'),
                            style: theme.textTheme.bodySmall),
                        const SizedBox(height: 10),
                        Wrap(spacing: 10, runSpacing: 10, children: [
                          for (final color in const [
                            Color(0xFF05080F),
                            Color(0xFF0A1220),
                            Color(0xFF111318),
                            Color(0xFF15121C),
                            Color(0xFF061522),
                            Color(0xFF091812),
                            Color(0xFF120D20),
                            Color(0xFF081C2B),
                            Color(0xFF10172E),
                            Color(0xFF0D1B18)
                          ])
                            _swatch(context, color, controller.background,
                                () => controller.setCustom(background: color)),
                          _customButton(
                              context,
                              _s('Свой фон', 'Custom background'),
                              controller.customBackground,
                              true),
                        ]),
                      ]),
                )),
    ]);
  }

  Widget _preset(BuildContext context, ThemeController controller,
      ThemePreset preset, String name, Color background, Color accent) {
    final selected = controller.preset == preset;
    final displayName = !english
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
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w400)),
            ]),
          ),
        ));
  }

  Widget _swatch(BuildContext context, Color color, Color selected,
          VoidCallback onTap) =>
      Semantics(
        label: 'Цвет #${color.toARGB32().toRadixString(16).substring(2)}',
        selected: color == selected,
        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              height: 42,
              width: 42,
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
              builder: (_) =>
                  _ColorDialog(initial: initial, background: background));
          if (color != null) {
            await controller.setCustom(
                accent: background ? null : color,
                background: background ? color : null);
          }
        },
      );
}

class _ColorDialog extends StatefulWidget {
  const _ColorDialog({required this.initial, required this.background});
  final Color initial;
  final bool background;
  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
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
      setState(() => error = 'Введите 6 символов, например 8BB9F4');
      return;
    }
    final color = Color(0xFF000000 | int.parse(raw, radix: 16));
    if (widget.background && color.computeLuminance() > .06) {
      setState(() => error = 'Для тёмной темы выберите более тёмный фон');
      return;
    }
    if (!widget.background && color.computeLuminance() < .25) {
      setState(() => error = 'Выберите светлее, чтобы кнопки были читаемыми');
      return;
    }
    Navigator.pop(context, color);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.background ? 'Свой фон' : 'Свой акцент'),
        content: SizedBox(
          width: 320,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Палитра', style: Theme.of(context).textTheme.bodySmall),
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
                        labelText: 'Или введите HEX',
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
              child: const Text('Отмена')),
          FilledButton(onPressed: submit, child: const Text('Применить'))
        ],
      );
}
