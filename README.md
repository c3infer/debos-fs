# debos-fs
This repository aims to provide an easy to use scripts to create configurable and lightweight file systems.
First you need to install a docker container with arm64 emulation enabled. For now all things are tested in our customized container of opencca [link](https://github.com/comet-cc/opencca-build/tree/test)

## 1 Build the file system
 
To initially build the file system `build.sh` is provided. To see full range of options:
```
./build.sh -h
```

Minimal cpio.gz, no Python:
```
./build.sh --format cpio.gz --py-enable 0
```

ext4 image, Python enabled with installed packages specified in `requirements.txt`:
```
./build.sh --format ext4 --py-enable 1 --reqs-file ./requirements.txt
```

overlaying file from a folder into the file system:
```
./build.sh --overlay ./overlay --overkay-dest /root
```

Just show what would run:
```
./build.sh --dry-run --format cpio
```
## 2 Booting the file system
In order to finally boot the file system, you must add an appropriate kernel command line argument to booting script in qemu/kvmtool.
If creating an `ext4` file system, add `root=/dev/vda1 rw`, otherwise, add `rdinit=/sbin/init` to the kernel commnad line arguments.

**Hint for Qemu**: The default setting is compatible with kvmtool. However, in order to use the created file system with Qemu, you must run the build script `build.sh` with an additional flag `--console hvc0`, and add `concole=hvc0` to kernel command line arguments.

## 3 Overlay the file system after creation
Script `overlay-into-artifact.sh` is provided to simply add more files into the file system without rebuilding it. It works with different types of artifacts (cpio.gz, cpio, ext4)
```
./overlay-into-artifact.sh  --overlay ./overlay --dest /root --artifact cpio.gz
```

