#!/usr/bin/env python3
"""Enable the sing-box-lx XHTTP transport in its Apple libbox build tags."""

from pathlib import Path
import sys


if len(sys.argv) != 2:
    raise SystemExit("Usage: enable_apple_xhttp.py <sing-box-lx-source>")

source = Path(sys.argv[1])
builder = source / "cmd/internal/build_libbox/main.go"
if not builder.is_file():
    raise SystemExit(f"Apple libbox builder not found: {builder}")

# Xray is linked into the existing Libbox framework so the iOS Packet Tunnel
# has one Go runtime. The extension selects either core for each VPN session.
import subprocess

subprocess.run(
    ["go", "mod", "edit", "-require=github.com/xtls/xray-core@v1.260327.0"],
    cwd=source,
    check=True,
)
xray_api = source / "experimental/libbox/ghostbox_xray.go"
xray_api.write_text(r'''package libbox

import (
	"errors"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"sync"
	"time"

	xraycore "github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
	_ "github.com/xtls/xray-core/proxy/tun"
)

var ghostBoxXrayMu sync.Mutex
var ghostBoxXrayInstance *xraycore.Instance
var ghostBoxXrayStop chan struct{}

// StartXray starts Xray in the existing Libbox Go runtime. tunFD is owned by
// NetworkExtension and remains open until StopXray returns.
func StartXray(config string, tunFD int32, softMemoryLimitMB int32) error {
	ghostBoxXrayMu.Lock()
	defer ghostBoxXrayMu.Unlock()
	if ghostBoxXrayInstance != nil {
		return errors.New("Xray is already running")
	}
	if tunFD < 0 {
		return errors.New("NetworkExtension utun descriptor is invalid")
	}
	if softMemoryLimitMB < 25 {
		softMemoryLimitMB = 25
	}
	if softMemoryLimitMB > 50 {
		softMemoryLimitMB = 50
	}
	softLimit := uint64(softMemoryLimitMB) * 1024 * 1024
	debug.SetGCPercent(50)
	debug.SetMemoryLimit(int64(softLimit))
	if err := os.Setenv("xray.tun.fd", strconv.Itoa(int(tunFD))); err != nil {
		return err
	}
	instance, err := xraycore.StartInstance("json", []byte(config))
	if err != nil {
		_ = os.Unsetenv("xray.tun.fd")
		return err
	}
	ghostBoxXrayInstance = instance
	ghostBoxXrayStop = make(chan struct{})
	go func(stop <-chan struct{}) {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		var aboveSoftLimit bool
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				var stats runtime.MemStats
				runtime.ReadMemStats(&stats)
				if stats.HeapAlloc >= softLimit {
					if !aboveSoftLimit {
						runtime.GC()
						aboveSoftLimit = true
					}
					if stats.HeapAlloc >= 50*1024*1024 {
						debug.FreeOSMemory()
					}
				} else if stats.HeapAlloc < softLimit*4/5 {
					aboveSoftLimit = false
				}
			}
		}
	}(ghostBoxXrayStop)
	return nil
}

// StopXray stops Xray and restores the shared Go runtime's default limit.
func StopXray() error {
	ghostBoxXrayMu.Lock()
	defer ghostBoxXrayMu.Unlock()
	if ghostBoxXrayStop != nil {
		close(ghostBoxXrayStop)
		ghostBoxXrayStop = nil
	}
	var err error
	if ghostBoxXrayInstance != nil {
		err = ghostBoxXrayInstance.Close()
		ghostBoxXrayInstance = nil
	}
	_ = os.Unsetenv("xray.tun.fd")
	debug.SetMemoryLimit(math.MaxInt64)
	return err
}
''')
api_text = xray_api.read_text()
api_text = api_text.replace('"math"\n', '', 1)
api_text = api_text.replace('debug.SetMemoryLimit(math.MaxInt64)', 'debug.SetMemoryLimit(-1)', 1)
xray_api.write_text(api_text)
subprocess.run(["go", "mod", "tidy"], cwd=source, check=True)

text = builder.read_text()
tag = '\tdarwinTags = append(darwinTags, "with_dhcp", "grpcnotrace")'
if 'sharedTags = append(sharedTags, "with_xhttp")' not in text:
    if tag not in text:
        raise SystemExit("Could not locate sing-box-lx Apple build-tag list")
    text = text.replace(
        tag,
        tag + '\n\tsharedTags = append(sharedTags, "with_xhttp")',
        1,
    )
    builder.write_text(text)

# Apply the pinned upstream Apple OOM collector's aggressive GC setting even
# when the host app supplies a soft memory budget. The independent 50 MiB
# adaptive cleanup policy remains active for iOS Network Extensions.
setup = source / "experimental/libbox/setup.go"
setup_text = setup.read_text()
fallback = """\t\tif sOOMMemoryLimit == 0 && C.IsIos {
\t\t\tsOOMMemoryLimit = oomkiller.DefaultAppleNetworkExtensionMemoryLimit
\t\t\tdebug.SetGCPercent(oomkiller.DefaultAppleNetworkExtensionGCPercent)
\t\t}"""
replacement = """\t\tif C.IsIos {
\t\t\tdebug.SetGCPercent(oomkiller.DefaultAppleNetworkExtensionGCPercent)
\t\t}
\t\tif sOOMMemoryLimit == 0 && C.IsIos {
\t\t\tsOOMMemoryLimit = oomkiller.DefaultAppleNetworkExtensionMemoryLimit
\t\t}"""
if replacement not in setup_text:
    if fallback not in setup_text:
        raise SystemExit("Could not locate sing-box-lx iOS OOM/GC setup")
    setup.write_text(setup_text.replace(fallback, replacement, 1))
setup_text = setup.read_text()
soft_limit = "debug.SetMemoryLimit(sOOMMemoryLimit * 4 / 5)"
if soft_limit in setup_text:
    setup.write_text(setup_text.replace(
        soft_limit,
        "debug.SetMemoryLimit(sOOMMemoryLimit)",
        1,
    ))
