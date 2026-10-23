import 'dart:async';
import 'dart:io';

/// Stops a speed test when its connection stops making progress.
class SpeedTestActivity {
  SpeedTestActivity({
    this.inactivityTimeout = const Duration(seconds: 5),
  }) {
    recordActivity();
  }

  final Duration inactivityTimeout;
  final Completer<void> _expired = Completer<void>();
  final Set<HttpClient> _clients = <HttpClient>{};
  Timer? _timer;
  bool _disposed = false;

  bool get timedOut => _expired.isCompleted;

  void throwIfInactive() {
    if (timedOut) {
      throw TimeoutException('Speed test received no data', inactivityTimeout);
    }
    if (_disposed) throw StateError('Speed test has finished');
  }

  void recordActivity() {
    throwIfInactive();
    _timer?.cancel();
    _timer = Timer(inactivityTimeout, () {
      _expired.complete();
      _closeClients();
    });
  }

  void attachClient(HttpClient client) {
    throwIfInactive();
    _clients.add(client);
  }

  void detachClient(HttpClient client) => _clients.remove(client);

  Future<T> run<T>(Future<T> Function() operation) async {
    throwIfInactive();
    try {
      return await Future.any<T>([
        Future<T>.sync(operation),
        _expired.future.then<T>((_) => throw TimeoutException(
            'Speed test received no data', inactivityTimeout)),
      ]);
    } finally {
      dispose();
    }
  }

  void _closeClients() {
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _closeClients();
  }
}
