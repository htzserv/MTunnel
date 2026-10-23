MTunnel package bundle
Target: Ubuntu 24.04 (Noble), amd64 / x86_64.

Raw ELF files in manifest.txt are checked against SHA-256 by MTunnel:
  bh, rathole, paqet, gost, haproxy, realm

The .deb files are downloaded from the configured Ubuntu 24.04 repositories,
so iperf3 and libiperf0 use matching Ubuntu builds. qrencode and socat are not
included because the current MTunnel source does not use them.

Upstream archives are also retained for local use. If you maintain a separate
mirror server, copy these archive assets there separately; uploading to GitHub
does not update MTUNNEL_MIRROR_BASE automatically. The bundle builder does not
install or upgrade packages on the build server; it only runs apt-get update to
refresh indexes and downloads files. At runtime, MTunnel's patched installer
uses APT to resolve transitive dependencies from configured Ubuntu repositories,
so repository connectivity is required.

Upload the CONTENTS of the generated temp/ folder to the root of htzserv/MTunnel
on the main branch. Do not upload temp/ as an extra nested directory.
