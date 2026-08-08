# MTunnel modification notes

This build keeps the existing project modules and Web UI behavior intact while updating:

- Initial installer core set: main, mgre, mporter, mxlan, mrathole, mweb, mstats.
- `mstat` compatibility command is deployed alongside `mstats`.
- Local-first module deployment and offline install via `install.sh --offline`.
- Missing non-core modules continue to be downloaded on demand by `main.sh` and cached in `/root/mtunnel`.
- Progress bars across the existing progress-enabled modules now use one consistent linear `-` style with colored filled/remaining sections.
- Main module download, binary download, core update, and offline deployment paths use the same linear progress presentation.
- Main dashboard header/menu presentation was polished while preserving the existing menu numbers and actions.
- Web UI credentials/default behavior were intentionally not changed.
- No existing module files or package assets were removed.
