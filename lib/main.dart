import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'app.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GhostBoxApp());
  final updateIndex = args.indexOf('--ghostbox-updated');
  if (updateIndex >= 0 && updateIndex + 1 < args.length) {
    final handoffDirectory = args[updateIndex + 1];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(File('$handoffDirectory/started').writeAsString('$pid\n'));
    });
  }
}
