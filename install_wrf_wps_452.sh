#!/usr/bin/env bash
# Compatibility entry point for the original WRF 4.5.2 + WPS 4.5 installer.
set -Eeuo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$script_dir/install_wrf_wps.sh" --wrf-version 4.5.2 --base "$script_dir" "$@"
