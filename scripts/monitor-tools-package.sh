#!/bin/bash
# Source this helper after setting task_root and a run-specific external test_root.
# Compile the package once; consumers link its real products and use Bundle.module.
monitor_package="$task_root/Packages/MonitorTools"
monitor_scratch="$test_root/monitor-package"
export CLANG_MODULE_CACHE_PATH="$test_root/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$test_root/modules"
monitor_package_build() {
  local product
  for product in MonitorToolsCore MonitorToolsMetal MonitorToolsUI; do
    xcrun swift build --package-path "$monitor_package" --scratch-path "$monitor_scratch" --cache-path "$test_root/package-cache" \
      --configuration release --arch arm64 --product "$product" \
      -Xswiftc -strict-concurrency=complete || return $?
  done
  monitor_bin="$(xcrun swift build --package-path "$monitor_package" --scratch-path "$monitor_scratch" --cache-path "$test_root/package-cache" \
    --configuration release --arch arm64 --show-bin-path)" || return $?
  monitor_link_args=(-I "$monitor_bin" -I "$monitor_bin/Modules" -L "$monitor_bin" \
    -lMonitorToolsUI -lMonitorToolsMetal -lMonitorToolsCore \
    -framework SwiftUI -framework Metal -framework MetalKit -framework CoreVideo -framework CoreMedia)
  local bundle found_resource=false
  shopt -s nullglob
  for bundle in "$monitor_bin"/*.bundle; do
    cp -R "$bundle" "$test_root/" || return $?
    if [[ "$bundle" == *MonitorToolsMetal.bundle ]]; then found_resource=true; fi
  done
  shopt -u nullglob
  [[ "$found_resource" == true ]] || { echo 'MonitorToolsMetal resource bundle missing from package products.' >&2; return 1; }
}
