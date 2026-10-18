# Changelog

## 1.2.0

- Added MTunnel Doctor to the main dashboard and installer.
- MTunnel Doctor now uses the exact same shared master header renderer as the main dashboard.
- Moved Doctor into the Tools & Benchmark group so options 7, 8, and 9 stay together.
- Moved `mdoctor.sh` to the repository root; no runtime `tools/` directory is required.
- Added full, network/IPv6, firewall/port, core/script, and system-service diagnostics.
- Added safe repair actions and diagnostic report export.
- Removed repository/update SHA manifest dependency and update-only SHA display.
- Made upgrades/downgrades symmetric: any selected version can replace any other compatible version.
- Added main CLI shortcuts for Doctor, status, report, GitHub/mirror sync, local deployment, and version.
- Simplified the public repository layout; runtime does not depend on tests, release, or config directories.
- Retained syntax validation and shared-core API/layout compatibility checks.
