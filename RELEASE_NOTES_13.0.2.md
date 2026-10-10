# MTunnel v13.0.2 — Stable Theme Restoration

Source of visual baseline: uploaded `MTunnel-main_10(1).zip` (v12 series).
Source of features: MTunnel v13.0.1 live-update/backhaul-ping patch.

## Appearance
- Existing module headers, fixed-width borders, status counters and color constants left untouched.
- Reintroduced stable MDesign tree layout: separated provision, configuration, monitoring, and system areas.
- Recolored every top-level and secondary menu entry using the original semantic palette (cyan/green/magenta/yellow/red/white).
- Standardized selection prompts and back entries, including peer-link screens and submenus.
- Kept existing update badges in yellow with original 'Update Available' terminology.

## Functionality preserved
- Peer setup link export/import for GRE, VXLAN, Backhaul, Rathole, Paqet.
- All V13 hierarchical create/edit/forwarding/system and optional BBR workflows.
- Update polling and SIGUSR1/SIGUSR2 live refresh, and Backhaul RTT / IPv6 improvements from 13.0.1.
- Validated partial patch installs with automatic original-script backups.

## Packaging
- The full archive includes unchanged local packages/tools from the stable archive.
- The small patch archive contains only changed shell scripts.

## Install (after unpacking, as root)
- Full archive: `sudo bash install.sh --local "$PWD" --no-launch`
- Patch archive: `sudo bash install.sh --local "$PWD" --patch --no-launch`
- Then exit old menus and launch `mtunnel` again.

## Checks
- `bash -n` across all updated scripts; verify original header functions are byte-identical except MODULE_VERSION used at display time.
- Static and mock-terminal menu snapshots, no real-tunnel traffic tests.
- Back up active tunnel config files before upgrading. Production servers were not tested.
