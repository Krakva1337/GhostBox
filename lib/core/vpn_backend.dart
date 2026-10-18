enum VpnState { disconnected, connecting, connected, error }

abstract interface class VpnBackend {
  VpnState get state;
  Future<void> connect(String profile);
  Future<void> disconnect();
}

