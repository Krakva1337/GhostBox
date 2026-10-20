import 'package:flutter/material.dart';
import 'app.dart';

void main(List<String> args) {
  // Update helpers use this marker to distinguish the clean post-install
  // relaunch from the old process that is being replaced.
  args.remove('--ghostbox-updated');
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GhostBoxApp());
}
