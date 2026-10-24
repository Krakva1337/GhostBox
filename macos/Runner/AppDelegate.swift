import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var trayChannel: FlutterMethodChannel?
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

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = NSImage(
        systemSymbolName: "network",
        accessibilityDescription: "GhostBox"
      )
      button.image?.isTemplate = true
      button.toolTip = "GhostBox · VPN"
    }

    let menu = NSMenu()
    let toggle = NSMenuItem(
      title: "Подключить / отключить",
      action: #selector(toggleConnection),
      keyEquivalent: ""
    )
    toggle.target = self
    menu.addItem(toggle)
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

  @objc private func toggleConnection() {
    trayChannel?.invokeMethod("toggleConnection", arguments: nil)
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
