import 'dart:convert';
import 'package:flutter/material.dart';
import 'glass_dialog.dart';
import '../theme/theme_controller.dart';

Future<Map<String, dynamic>?> showProfileJsonEditor(
  BuildContext context, {
  required String title,
  required Map<String, dynamic> initial,
  bool english = false,
  bool optimizedMode = false,
}) async {
  final controller = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(initial));
  String? error;
  try {
    return await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, setState) => GlassAlertDialog(
                optimizedMode: optimizedMode,
                glassStrength: ThemeController.instance.glassStrength,
                title: Text(title),
                content: SizedBox(
                    width: 680,
                    height: MediaQuery.sizeOf(context).height * .65,
                    child: Column(children: [
                      Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                              english
                                  ? 'This config replaces generated core settings. GhostBox manages the local listener port. Reset JSON to return to app settings.'
                                  : 'Этот JSON заменяет конфиг из настроек приложения. Порт local задаёт GhostBox. Сбросьте JSON, чтобы вернуть настройки приложения.',
                              style: Theme.of(context).textTheme.bodySmall)),
                      Expanded(
                          child: GlassDialogSurface(
                        optimizedMode: optimizedMode,
                        glassStrength: ThemeController.instance.glassStrength,
                        radius: 14,
                        sigma: 5,
                        padding: const EdgeInsets.all(5),
                        backgroundColor:
                            Theme.of(context).colorScheme.surfaceContainer,
                        child: TextField(
                            controller: controller,
                            expands: true,
                            minLines: null,
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 12),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: Colors.white.withValues(alpha: .025),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                    color: Colors.white.withValues(alpha: .10)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: .72)),
                              ),
                            )),
                      )),
                      if (error != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(error!,
                                style:
                                    const TextStyle(color: Colors.redAccent)))
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(english ? 'Cancel' : 'Отмена')),
                  FilledButton(
                      onPressed: () {
                        try {
                          final parsed = jsonDecode(controller.text);
                          if (parsed is! Map<String, dynamic> ||
                              parsed['inbounds'] is! List ||
                              parsed['outbounds'] is! List)
                            throw const FormatException(
                                'Ожидаются объект JSON, inbounds и outbounds');
                          Navigator.pop(context, parsed);
                        } on Object catch (e) {
                          setState(() => error = e.toString());
                        }
                      },
                      child: Text(english ? 'Save' : 'Сохранить'))
                ],
              )),
    );
  } finally {
    controller.dispose();
  }
}
