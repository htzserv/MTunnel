# MTunnel 1.2.0 — Doctor Release

MTunnel is a modular Linux tunnel-management toolkit. Version 1.2.0 promotes MTunnel Doctor to a first-class module and makes release switching deliberately permissive.

## Highlights

- MTunnel Doctor: full health scan, IPv4/IPv6 checks, firewall/port diagnostics, core/script checks, failed-service review, safe repairs, and report export.
- Free version switching: upgrade or downgrade to any selected bundle/version. Numeric version direction never blocks deployment.
- Repository update SHA manifests are not required. Downloads still require HTTPS, non-empty content, valid Bash syntax, and a compatible shared-core API/layout.
- Main CLI: `mtunnel --doctor`, `--status`, `--report`, `--sync`, `--sync-mirror`, `--local PATH`, and `--version`.
- Offline/source override example included at `config/sources.conf.example`.

## Install

```bash
sudo bash install.sh --local .
```

Online:

```bash
curl -fsSL https://raw.githubusercontent.com/htzserv/MTunnel/main/install.sh | sudo bash -s -- --online
```

## Important

SHA-256/HMAC operations used internally by tunnel encryption, peer-code integrity, deterministic IDs, or local ownership tracking are unrelated to repository release verification and remain in place.
