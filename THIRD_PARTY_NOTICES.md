# Third-party software

This repository's scripts and configuration are licensed under GPL-3.0-or-later;
see `LICENSE`.

By default, the image includes unmodified sing-box v1.14.2 from
`ghcr.io/sagernet/sing-box:v1.14.2`:

- Project: https://github.com/SagerNet/sing-box
- Corresponding upstream source: https://github.com/SagerNet/sing-box/tree/v1.14.2
- Source archive: https://github.com/SagerNet/sing-box/archive/refs/tags/v1.14.2.tar.gz
- Upstream license and additional naming notice: `LICENSE.sing-box`

`SINGBOX_VERSION` can select another release at build time. For such a build,
use that release's tag for the corresponding source links above, and review
and update `LICENSE.sing-box` if its upstream notice has changed.

This is an independent packaging project and does not imply endorsement by
SagerNet. The upstream naming notice remains applicable to sing-box.

Debian and the installed packages retain their respective licenses. Package
copyright notices are available in `/usr/share/doc` inside the image. When
redistributing images, retain applicable notices and provide corresponding
source as required by each component's license; a repository license does not
replace those component obligations.
