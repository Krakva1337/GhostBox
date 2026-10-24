import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GhostBoxAppIcon") {
      let channel = FlutterMethodChannel(
        name: "app.ghostbox.ghostbox/app_icon",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        guard call.method == "setAppIcon",
              let arguments = call.arguments as? [String: Any],
              let variant = arguments["variant"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard UIApplication.shared.supportsAlternateIcons else {
          result(false)
          return
        }
        guard variant != "custom" else {
          result(false)
          return
        }
        let iconName = variant == "aurora" ? nil : "AppIcon_\(variant.capitalized)"
        UIApplication.shared.setAlternateIconName(iconName) { error in
          if let error = error {
            result(FlutterError(code: "icon_change_failed", message: error.localizedDescription, details: nil))
          } else {
            result(true)
          }
        }
      }
    }

    guard let vpnRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "GhostBoxVpn") else {
      return
    }
    let vpnChannel = FlutterMethodChannel(
      name: "app.ghostbox.ghostbox/vpn",
      binaryMessenger: vpnRegistrar.messenger()
    )
    vpnChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "vpn_unavailable", message: "App delegate is unavailable", details: nil))
        return
      }
      switch call.method {
      case "startVpn":
        guard let arguments = call.arguments as? [String: Any],
              let config = arguments["config"] as? String else {
          result(FlutterError(code: "invalid_vpn_config", message: "Missing sing-box config", details: nil))
          return
        }
        self.startVpn(config: config, profileName: arguments["profileName"] as? String ?? "GhostBox", result: result)
      case "stopVpn":
        self.stopVpn(result: result)
      case "vpnState":
        self.readVpnState(result: result)
      case "vpnSnapshot":
        self.readVpnSnapshot(result: result)
      case "vpnConnectedAt":
        self.loadTunnelManager { manager, error in
          result(manager?.connection.connectedDate.map { Int64($0.timeIntervalSince1970 * 1000) })
        }
      case "vpnError":
        result(UserDefaults.standard.string(forKey: "GhostBoxVpnError"))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var tunnelBundleIdentifier: String {
    "\(Bundle.main.bundleIdentifier ?? "app.ghostbox.ghostbox").PacketTunnel"
  }
  // Retaining the manager also retains the live NEVPNConnection. Reloading a
  // manager for every status read can otherwise race preference saves.
  private var tunnelManager: NETunnelProviderManager?
  private var mutationInProgress = false

  private func loadTunnelManager(_ completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    if let tunnelManager {
      completion(tunnelManager, nil)
      return
    }
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      DispatchQueue.main.async {
        guard error == nil else {
          completion(nil, error)
          return
        }
        let matches = managers?.filter {
          ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleIdentifier
        } ?? []
        // Reattach to an existing live extension after the host was terminated.
        let manager = matches.first(where: {
          $0.connection.status != .disconnected && $0.connection.status != .invalid
        }) ?? matches.first ?? NETunnelProviderManager()
        self.tunnelManager = manager
        completion(manager, nil)
      }
    }
  }

  private func beginMutation(_ result: @escaping FlutterResult) -> FlutterResult? {
    guard !mutationInProgress else {
      result(FlutterError(code: "vpn_busy", message: "A VPN operation is already in progress", details: nil))
      return nil
    }
    mutationInProgress = true
    return { value in
      DispatchQueue.main.async {
        self.mutationInProgress = false
        result(value)
      }
    }
  }

  private func waitForStop(_ manager: NETunnelProviderManager, deadline: Date,
                           completion: @escaping (Error?) -> Void) {
    switch manager.connection.status {
    case .disconnected, .invalid:
      completion(nil)
    default:
      guard Date() < deadline else {
        completion(NSError(domain: "GhostBoxVPN", code: 1, userInfo: [
          NSLocalizedDescriptionKey: "The previous VPN tunnel did not stop within 20 seconds"
        ]))
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        self.waitForStop(manager, deadline: deadline, completion: completion)
      }
    }
  }

  private func startVpn(config: String, profileName: String, result: @escaping FlutterResult) {
    guard let finish = beginMutation(result) else { return }
    guard let data = config.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
      finish(FlutterError(code: "invalid_vpn_config", message: "Invalid sing-box JSON config", details: nil))
      return
    }
    UserDefaults.standard.removeObject(forKey: "GhostBoxVpnError")
    loadTunnelManager { manager, error in
      guard let manager else {
        finish(FlutterError(code: "vpn_preferences_failed", message: error?.localizedDescription, details: nil))
        return
      }
      // Switching profiles never starts a second extension over a disconnecting
      // tunnel. Await actual NE state before saving or starting the replacement.
      if manager.connection.status != .disconnected && manager.connection.status != .invalid {
        manager.connection.stopVPNTunnel()
      }
      self.waitForStop(manager, deadline: Date().addingTimeInterval(20)) { stopError in
        guard stopError == nil else {
          finish(FlutterError(code: "vpn_stop_timeout", message: stopError?.localizedDescription, details: nil))
          return
        }
        let tunnel = NETunnelProviderProtocol()
        tunnel.providerBundleIdentifier = self.tunnelBundleIdentifier
        tunnel.serverAddress = profileName
        tunnel.providerConfiguration = ["app": "GhostBox", "profileName": profileName]
        tunnel.disconnectOnSleep = false
        manager.protocolConfiguration = tunnel
        manager.localizedDescription = "GhostBox VPN"
        manager.isEnabled = true
        manager.saveToPreferences { saveError in
          guard saveError == nil else {
            finish(FlutterError(code: "vpn_preferences_failed", message: saveError?.localizedDescription, details: nil))
            return
          }
          manager.loadFromPreferences { reloadError in
            guard reloadError == nil else {
              finish(FlutterError(code: "vpn_preferences_failed", message: reloadError?.localizedDescription, details: nil))
              return
            }
            do {
              try manager.connection.startVPNTunnel(options: [
                "configContent": config as NSString,
                "systemProxyEnabled": false as NSNumber,
                "excludeAPNsRoute": true as NSNumber,
              ])
              finish(nil)
            } catch {
              UserDefaults.standard.set(error.localizedDescription, forKey: "GhostBoxVpnError")
              finish(FlutterError(code: "vpn_start_failed", message: error.localizedDescription, details: nil))
            }
          }
        }
      }
    }
  }

  private func stopVpn(result: @escaping FlutterResult) {
    guard let finish = beginMutation(result) else { return }
    loadTunnelManager { manager, error in
      guard let manager else {
        finish(FlutterError(code: "vpn_preferences_failed", message: error?.localizedDescription, details: nil))
        return
      }
      manager.connection.stopVPNTunnel()
      self.waitForStop(manager, deadline: Date().addingTimeInterval(20)) { stopError in
        if let stopError {
          finish(FlutterError(code: "vpn_stop_timeout", message: stopError.localizedDescription, details: nil))
        } else {
          finish(nil)
        }
      }
    }
  }

  private func stateName(_ status: NEVPNStatus) -> String {
    switch status {
    case .connecting, .reasserting: return "connecting"
    case .connected: return "connected"
    case .disconnecting: return "disconnecting"
    case .invalid, .disconnected: return "disconnected"
    @unknown default: return "disconnected"
    }
  }

  private func readVpnSnapshot(result: @escaping FlutterResult) {
    loadTunnelManager { manager, error in
      guard let manager else {
        result(FlutterError(code: "vpn_preferences_failed", message: error?.localizedDescription, details: nil))
        return
      }
      var snapshot: [String: Any] = [
        "state": self.stateName(manager.connection.status),
        "profileName": (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["profileName"] as? String ?? "",
      ]
      if let date = manager.connection.connectedDate {
        snapshot["connectedAt"] = Int64(date.timeIntervalSince1970 * 1000)
      }
      if #available(iOS 16.0, *), manager.connection.status == .disconnected {
        manager.connection.fetchLastDisconnectError { error in
          if let error { snapshot["error"] = error.localizedDescription }
          DispatchQueue.main.async { result(snapshot) }
        }
      } else {
        result(snapshot)
      }
    }
  }

  private func readVpnState(result: @escaping FlutterResult) {
    loadTunnelManager { manager, error in
      guard let manager else {
        result(FlutterError(code: "vpn_preferences_failed", message: error?.localizedDescription, details: nil))
        return
      }
      result(self.stateName(manager.connection.status))
    }
  }
}
