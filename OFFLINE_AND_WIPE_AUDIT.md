# MTunnel Offline / Nuclear Wipe audit

## Findings fixed

1. The previous installer downloaded far more than the requested core set. It now installs only:
   `main.sh`, `mgre.sh`, `mporter.sh`, `mxlan.sh`, `mrathole.sh`, `mweb.sh`, `mstats.sh`.
2. Local-first behavior is explicit. `--offline` never calls GitHub.
3. When a module is missing locally, the normal `run_mod` path downloads it and caches it under `/root/mtunnel`.
4. `mstat` is provided as an alias to `mstats`.
5. The old Nuclear Wipe removed shared `/etc/haproxy` and `/etc/wireguard` trees and could affect unrelated infrastructure. Those shared directories are now preserved.
6. The old wipe used broad TCPMSS/interface matching. The new version removes only explicitly named MTunnel chains/rules and only interfaces with the project's known naming prefixes.
7. Wipe confirmation now requires the exact phrase `WIPE-MTUNNEL`.
8. Progress output in the central installer/wipe/download path uses a single-line hyphen bar.

## Important limitation

A completely generic interface name cannot prove ownership after the fact. The wipe therefore intentionally avoids deleting interfaces outside the known MTunnel prefixes. If a custom MTunnel interface uses a different name, it must be removed manually.

Web UI defaults were not changed.
