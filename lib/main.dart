import 'package:flutter/material.dart';
import 'app.dart';

void main(List<String> args) {
  // Flutter provides a fixed-length argument list. Update relaunch markers are
  // intentionally ignored here; mutating `args` would throw before the window
  // is created.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GhostBoxApp());
}
