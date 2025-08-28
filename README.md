# debos-fs
This repository aims to provide an easy to use scripts to create configurable and lightweight file systems.
First you need to install a docker container with arm64 emulation enabled. For now all things are tested in opencca conteiner [link](sadas)

## Build the file system
 
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

## Overlay the file system
Script `overlay-into-artifact.sh` is provided to simply add more files into the file system without rebuilding it. It works with different types of artifacts (cpio.gz, cpio, ext4)
```
./overlay-into-artifact.sh  --overlay ./overlay --dest /root --artifact cpio.gz
```

