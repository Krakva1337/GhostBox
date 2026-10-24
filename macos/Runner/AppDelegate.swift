import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var trayChannel: FlutterMethodChannel?
  private var statusMenuItem: NSMenuItem?
  private var connectionMenuItem: NSMenuItem?
  private var isConnected = false
  private var isConnecting = false
  private(set) var isQuitting = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  func installMenuBarItem(messenger: FlutterBinaryMessenger) {
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
