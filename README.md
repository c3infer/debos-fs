# debos-fs
This repository aims to provide an easy to use scripts to create configurable and lightweight file systems.


First you need to install a docker container with arm64 emulation enabled


 
To see full range of options:
```
./build.sh -h
```

Minimal cpio.gz, no Python:
```
./build.sh --format cpio.gz --py-enable 0
```

ext4 image, Python enabled from a file:
```
./build.sh --format ext4 --py-enable 1 --reqs-file ./requirements.txt
```

tarball, keep only en_GB locales:
```
./build.sh --format tar --keep-locales en_GB
```

Just show what would run:
```
./build.sh --dry-run --format cpio
```
