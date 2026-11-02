import Cocoa
import FlutterMacOS
import Security

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var trayChannel: FlutterMethodChannel?
  private var credentialChannel: FlutterMethodChannel?
  private var statusMenuItem: NSMenuItem?
  private var connectionMenuItem: NSMenuItem?
  private var isConnected = false
  private var isConnecting = false
  private(set) var isQuitting = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  func installMenuBarItem(messenger: FlutterBinaryMessenger) {
    installCredentialChannel(messenger: messenger)
    guard statusItem == nil else { return }

    let channel = FlutterMethodChannel(
      name: "app.ghostbox.ghostbox/system_tray",
      binaryMessenger: messenger
    )
    trayChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "app_closed", message: "GhostBox is closing", details: nil))
        return
      }
      guard call.method == "setConnectionState",
            let state = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.updateConnectionState(
        connected: state["connected"] as? Bool ?? false,
        connecting: state["connecting"] as? Bool ?? false
      )
      result(nil)
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      if let appIcon = NSApp.applicationIconImage.copy() as? NSImage {
        appIcon.size = NSSize(width: 18, height: 18)
        appIcon.isTemplate = false
        button.image = appIcon
      }
      button.image?.accessibilityDescription = "GhostBox"
      button.toolTip = "GhostBox · VPN"
    }

    let menu = NSMenu()
    let toggle = NSMenuItem(
      title: "Подключиться",
      action: #selector(performConnectionAction),
      keyEquivalent: ""
    )
    toggle.target = self
    connectionMenuItem = toggle
    menu.addItem(toggle)
    let status = NSMenuItem(title: "Статус: Отключено", action: nil, keyEquivalent: "")
    status.isEnabled = false
    statusMenuItem = status
    menu.insertItem(status, at: 0)
    menu.addItem(.separator())

    let open = NSMenuItem(
      title: "Открыть GhostBox",
      action: #selector(showGhostBox),
      keyEquivalent: ""
    )
    open.target = self
    menu.addItem(open)

    let quit = NSMenuItem(
      title: "Завершить GhostBox",
      action: #selector(quitGhostBox),
      keyEquivalent: ""
    )
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    statusItem = item
  }

  /// Exposes only the GhostBox TUN administrator credential to the Dart side.
  /// The service and account are fixed so callers cannot use this channel as
  /// a general-purpose Keychain reader or writer.
  private func installCredentialChannel(messenger: FlutterBinaryMessenger) {
    guard credentialChannel == nil else { return }

    let channel = FlutterMethodChannel(
      name: "app.ghostbox.ghostbox/macos_keychain",
      binaryMessenger: messenger
    )
    credentialChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getAdminPassword":
        self.readAdminPassword(result: result)
      case "setAdminPassword":
        guard let arguments = call.arguments as? [String: Any],
              let password = arguments["password"] as? String else {
          result(FlutterError(
            code: "invalid_arguments",
            message: "A password string is required",
            details: nil
          ))
          return
        }
        self.writeAdminPassword(password, result: result)
      case "deleteAdminPassword":
        self.deleteAdminPassword(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private let credentialService = "app.ghostbox.ghostbox.macos.admin-password"
  private let credentialAccount = "tun-administrator"

  private var credentialQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: credentialService,
      kSecAttrAccount as String: credentialAccount,
    ]
  }

  private func readAdminPassword(result: FlutterResult) {
    var query = credentialQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      result(nil)
      return
    }
    guard status == errSecSuccess else {
      result(keychainError(status, operation: "read"))
      return
    }
    guard let data = item as? Data,
          let password = String(data: data, encoding: .utf8) else {
      result(FlutterError(
        code: "keychain_invalid_data",
        message: "The stored GhostBox credential is not valid UTF-8",
        details: nil
      ))
      return
    }
    result(password)
  }

  private func writeAdminPassword(_ password: String, result: FlutterResult) {
    let value = Data(password.utf8)
    let updates: [String: Any] = [kSecValueData as String: value]
    let updateStatus = SecItemUpdate(credentialQuery as CFDictionary, updates as CFDictionary)

    if updateStatus == errSecSuccess {
      result(nil)
      return
    }
    guard updateStatus == errSecItemNotFound else {
      result(keychainError(updateStatus, operation: "update"))
      return
    }

    var item = credentialQuery
    item[kSecValueData as String] = value
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      result(keychainError(addStatus, operation: "save"))
      return
    }
    result(nil)
  }

  private func deleteAdminPassword(result: FlutterResult) {
    let status = SecItemDelete(credentialQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      result(keychainError(status, operation: "delete"))
      return
    }
    result(nil)
  }

  private func keychainError(_ status: OSStatus, operation: String) -> FlutterError {
    let message = (SecCopyErrorMessageString(status, nil) as String?)
      ?? "Unknown Keychain error"
    return FlutterError(
      code: "keychain_\(operation)_\(status)",
      message: message,
      details: ["status": status]
    )
  }

  private func updateConnectionState(connected: Bool, connecting: Bool) {
    isConnected = connected
    isConnecting = connecting && !connected

    if isConnected {
      statusMenuItem?.title = "Статус: Подключено"
      connectionMenuItem?.title = "Отключиться"
      connectionMenuItem?.isEnabled = true
    } else if isConnecting {
      statusMenuItem?.title = "Статус: Подключение…"
      connectionMenuItem?.title = "Подключение…"
      connectionMenuItem?.isEnabled = false
    } else {
      statusMenuItem?.title = "Статус: Отключено"
      connectionMenuItem?.title = "Подключиться"
      connectionMenuItem?.isEnabled = true
    }
  }

  @objc private func performConnectionAction() {
    guard !isConnecting else { return }
    trayChannel?.invokeMethod(isConnected ? "disconnect" : "connect", arguments: nil)
  }

  @objc private func showGhostBox() {
    NSApp.activate(ignoringOtherApps: true)
    (NSApp.windows.first { $0 is MainFlutterWindow })?.makeKeyAndOrderFront(nil)
  }

  @objc private func quitGhostBox() {
    isQuitting = true
    NSApp.terminate(nil)
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag { showGhostBox() }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
