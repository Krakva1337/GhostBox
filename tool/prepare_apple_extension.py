#!/usr/bin/env python3
"""Bind the pinned upstream Packet Tunnel target to the GhostBox iOS host."""
from pathlib import Path
import os
import re
import sys

root = Path(__file__).resolve().parent.parent
source = Path(sys.argv[1]).resolve()
client = source / "clients/apple"
project = client / "sing-box.xcodeproj/project.pbxproj"
text = project.read_text()
version_string = re.search(r"^version:\s*(\S+)", (root / "pubspec.yaml").read_text(), re.M).group(1)
version = re.match(r"\d+\.\d+\.\d+", version_string).group(0)
build = version_string.partition("+")[2] or "1"
if not build.isdigit():
    raise SystemExit("The iOS build number must be numeric")
team = os.environ.get("GHOSTBOX_APPLE_TEAM_ID", "")
if team and not re.fullmatch(r"[A-Z0-9]{10}", team):
    raise SystemExit("GHOSTBOX_APPLE_TEAM_ID must be a 10-character Apple team ID")

# Refuse a changed source layout instead of shipping an unlinked extension.
for identifier, product in (("3A096F852A4ED3DE00D4A2ED", "Extension"),
                            ("3A096F862A4ED3DE00D4A2ED", "Extension.appex"),
                            ("3AEC211D2A459B4700A63465", "Library.framework")):
    if f"{identifier} /* {product} */" not in text:
        raise SystemExit(f"Upstream Apple project changed: missing {product} ({identifier})")

# Both the extension and Library use Bundle.main to look up the application
# group. Remove the upstream developer's team throughout the dependency graph.
text = re.sub(r"BASE_PACKAGE_IDENTIFIER = [^;]+;", "BASE_PACKAGE_IDENTIFIER = app.ghostbox.ghostbox;", text)
text = re.sub(r"DEVELOPMENT_TEAM = [^;]+;", f'DEVELOPMENT_TEAM = "{team}";', text)
pattern = re.compile(r"\t\t[A-Fa-f0-9]+ /\* (?:Debug|Release) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;[\s\S]*?\n\t\t\};")
updated = 0
for match in reversed(list(pattern.finditer(text))):
    block = match.group(0)
    if "INFOPLIST_FILE = Extension/Info.plist;" not in block:
        continue
    values = {
        "PRODUCT_BUNDLE_IDENTIFIER": "app.ghostbox.ghostbox.PacketTunnel",
        "APP_GROUP_IDENTIFIER": "group.app.ghostbox.ghostbox",
        "BASE_PACKAGE_IDENTIFIER": "app.ghostbox.ghostbox",
        "MARKETING_VERSION": version,
        "CURRENT_PROJECT_VERSION": build,
        "INFOPLIST_KEY_CFBundleDisplayName": '"GhostBox VPN"',
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
        "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
        "APPLICATION_EXTENSION_API_ONLY": "YES",
    }
    for key, value in values.items():
        setting = re.compile(rf"\b{key} = [^;]+;")
        if setting.search(block):
            block = setting.sub(f"{key} = {value};", block)
        else:
            block = block.replace("buildSettings = {", f"buildSettings = {{\n\t\t\t\t{key} = {value};", 1)
    text = text[:match.start()] + block + text[match.end():]
    updated += 1
if updated != 2:
    raise SystemExit(f"Expected two Packet Tunnel configurations, found {updated}")
project.write_text(text)

# sing-box-lx adds a DNS-query callback to its libbox handler protocol. The
# stock Apple client does not display this stream, so provide an explicit
# no-op adapter to keep the upstream client compatible with that API.
command_client = client / "Library/Network/CommandClient.swift"
source_text = command_client.read_text()
dns_handler = """        func write(_ query: LibboxDnsQuery?) {
            // GhostBox does not consume the upstream DNS observability stream.
        }

"""
write_logs = "        func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {"
if "func write(_ query: LibboxDnsQuery?)" not in source_text:
    if write_logs not in source_text:
        raise SystemExit("Could not locate Apple command client log callback")
    command_client.write_text(source_text.replace(write_logs, dns_handler + write_logs, 1))

# Keep the iOS Network Extension on the app's soft Go memory budget. The
# OOM policy in sing-box-lx retains its independent 50 MiB hard cleanup cap.
provider = client / "Library/Network/ExtensionProvider.swift"
provider_text = provider.read_text()
old_ios_options = """        #else
            options.oomKillerEnabled = true
        #endif"""
new_ios_options = """        #else
            options.oomKillerEnabled = true
            let oomMemoryLimitMB = (effectiveOptions[\"oomMemoryLimitMB\"] as? NSNumber)?.int64Value ?? 25
            options.oomMemoryLimit = min(max(oomMemoryLimitMB, 25), 50) * 1024 * 1024
        #endif"""
if new_ios_options not in provider_text:
    if old_ios_options not in provider_text:
        raise SystemExit("Could not locate Apple extension iOS OOM setup")
    provider.write_text(provider_text.replace(old_ios_options, new_ios_options, 1))

# Xray uses Apple's utun descriptor directly. This separate Packet Tunnel path
# avoids starting sing-box when Xray was selected, while sharing the same
# Libbox framework and its single Go runtime.
provider_text = provider.read_text()
if "import Darwin" not in provider_text:
    provider_text = provider_text.replace(
        "import Foundation\n",
        "import Foundation\n#if os(iOS)\n    import Darwin\n#endif\n",
        1,
    )
if "startGhostBoxXray(effectiveOptions)" not in provider_text:
    setup_marker = """        do {
            try persistStartOptions(effectiveOptions)
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: persist start options: \\(error.localizedDescription)")
        }
"""
    xray_branch = setup_marker + """
        #if os(iOS)
            if effectiveOptions["ghostboxCore"] as? String == "xray" {
                do {
                    try await startGhostBoxXray(effectiveOptions)
                    UserDefaults(suiteName: "group.app.ghostbox.ghostbox")?.removeObject(forKey: "GhostBoxVpnError")
                    return
                } catch {
                    UserDefaults(suiteName: "group.app.ghostbox.ghostbox")?.set(error.localizedDescription, forKey: "GhostBoxVpnError")
                    throw error
                }
            }
        #endif
"""
    if setup_marker not in provider_text:
        raise SystemExit("Could not locate Apple extension startup options block")
    provider_text = provider_text.replace(setup_marker, xray_branch, 1)
    provider.write_text(provider_text)

provider_text = provider.read_text()
old_xray_branch = """            if effectiveOptions["ghostboxCore"] as? String == "xray" {
                try await startGhostBoxXray(effectiveOptions)
                return
            }
"""
new_xray_branch = """            if effectiveOptions["ghostboxCore"] as? String == "xray" {
                do {
                    try await startGhostBoxXray(effectiveOptions)
                    UserDefaults(suiteName: "group.app.ghostbox.ghostbox")?.removeObject(forKey: "GhostBoxVpnError")
                    return
                } catch {
                    UserDefaults(suiteName: "group.app.ghostbox.ghostbox")?.set(error.localizedDescription, forKey: "GhostBoxVpnError")
                    throw error
                }
            }
"""
if old_xray_branch in provider_text:
    provider.write_text(provider_text.replace(old_xray_branch, new_xray_branch, 1))

provider_text = provider.read_text()
if "private func startGhostBoxXray" not in provider_text:
    extension_provider_marker = """    private func startService() async throws {
"""
    xray_methods = r'''    #if os(iOS)
    private var ghostBoxXrayRunning = false

    private func findGhostBoxUtunFileDescriptor() -> Int32? {
        for fd in 0...1024 {
            var name = [CChar](repeating: 0, count: 128)
            var length = socklen_t(name.count)
            let result = name.withUnsafeMutableBytes { buffer in
                getsockopt(Int32(fd), 2, 2, buffer.baseAddress, &length)
            }
            if result == 0 && String(cString: name).hasPrefix("utun") {
                return Int32(fd)
            }
        }
        return nil
    }

    private func startGhostBoxXray(_ options: [String: NSObject]) async throws {
        guard let config = options["configContent"] as? String else {
            throw ExtensionStartupError("(packet-tunnel) Xray config is missing")
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        var excludedIPv4: [NEIPv4Route] = []
        var excludedIPv6: [NEIPv6Route] = []
        for address in options["serverEndpointIPs"] as? [String] ?? [] {
            if address.contains(":") {
                excludedIPv6.append(NEIPv6Route(destinationAddress: address, networkPrefixLength: 128))
            } else {
                excludedIPv4.append(NEIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255"))
            }
        }
        if (options["excludeAPNsRoute"] as? NSNumber)?.boolValue ?? false {
            excludedIPv4.append(NEIPv4Route(destinationAddress: "17.0.0.0", subnetMask: "255.0.0.0"))
        }
        ipv4.excludedRoutes = excludedIPv4
        let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = excludedIPv6
        settings.ipv4Settings = ipv4
        settings.ipv6Settings = ipv6
        settings.mtu = 1500
        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        try await setTunnelNetworkSettings(settings)

        guard let tunFD = findGhostBoxUtunFileDescriptor() else {
            throw ExtensionStartupError("(packet-tunnel) NetworkExtension utun descriptor was not found")
        }
        let limit = (options["oomMemoryLimitMB"] as? NSNumber)?.int32Value ?? 25
        var startError: NSError?
        LibboxStartXray(config, tunFD, min(max(limit, 25), 50), &startError)
        if let startError {
            throw ExtensionStartupError("(packet-tunnel) start Xray: \(startError.localizedDescription)")
        }
        ghostBoxXrayRunning = true
        writeMessage("(packet-tunnel): Xray TUN is running", level: .info)
    }

    private func stopGhostBoxXray() {
        guard ghostBoxXrayRunning else { return }
        var stopError: NSError?
        LibboxStopXray(&stopError)
        ghostBoxXrayRunning = false
        if let stopError {
            writeMessage("(packet-tunnel) stop Xray: \(stopError.localizedDescription)")
        }
    }
    #endif

'''
    if extension_provider_marker not in provider_text:
        raise SystemExit("Could not locate Apple startService method")
    provider_text = provider_text.replace(extension_provider_marker, xray_methods + extension_provider_marker, 1)
    provider.write_text(provider_text)

provider_text = provider.read_text()
updated_provider_text = provider_text.replace(
    "getsockopt(fd, 2, 2, buffer.baseAddress, &length)",
    "getsockopt(Int32(fd), 2, 2, buffer.baseAddress, &length)",
)
apns_marker = "        var excludedIPv4: [NEIPv4Route] = []\n"
apns_route = """        if (options["excludeAPNsRoute"] as? NSNumber)?.boolValue ?? false {
            excludedIPv4.append(NEIPv4Route(destinationAddress: "17.0.0.0", subnetMask: "255.0.0.0"))
        }
"""
if "destinationAddress: \"17.0.0.0\"" not in updated_provider_text:
    if apns_marker not in updated_provider_text:
        raise SystemExit("Could not locate Xray IPv4 exclusion routes")
    updated_provider_text = updated_provider_text.replace(apns_marker, apns_marker + apns_route, 1)
if updated_provider_text != provider_text:
    provider.write_text(updated_provider_text)
    provider_text = updated_provider_text
stop_marker = """        stopService()
        if let server = commandServer {
"""
stop_replacement = """        #if os(iOS)
            stopGhostBoxXray()
        #endif
        stopService()
        if let server = commandServer {
"""
if stop_replacement not in provider_text:
    if stop_marker not in provider_text:
        raise SystemExit("Could not locate Apple stopTunnel cleanup")
    provider.write_text(provider_text.replace(stop_marker, stop_replacement, 1))

# iOS only requires Network Extension and the shared container. Avoid demanding
# the upstream macOS sandbox/location/multicast entitlements for GhostBox.
(client / "Extension/Extension.entitlements").write_bytes((root / "ios/Runner/Runner.entitlements").read_bytes())
link = root / ".toolchains/apple-client"
if link.is_symlink():
    link.unlink()
elif link.exists():
    raise SystemExit(f"Refusing to replace non-symlink directory: {link}")
link.symlink_to(client, target_is_directory=True)
print(f"Prepared GhostBox Packet Tunnel {version} ({build}) from {source.name}")
