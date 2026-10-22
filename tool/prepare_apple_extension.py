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
