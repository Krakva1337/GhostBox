class UpdateStartup {
  UpdateStartup._();

  /// Completes once the post-update first-frame health check has run.
  static Future<void>? healthCheck;
}
