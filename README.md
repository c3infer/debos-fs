# debos-fs
This repository aims to provide an easy to use scripts to create configurable and lightweight file systems.
First you need to install a docker container with arm64 emulation enabled. For now all things are tested in our customized container of opencca ([link](https://github.com/comet-cc/opencca-build)).

## Quick workflow

- `buildfs.sh`: rebuild a fresh disk image (`out/rootfs.img`) from recipe + overlay.
- `overlayfs.sh`: apply only the current `overlay/` changes into an existing `out/rootfs.img` (faster than full rebuild).

Typical usage:
```bash
# Full rebuild
./buildfs.sh

# Fast overlay refresh into existing image
./overlayfs.sh
```