#!/bin/bash 

cd "$( dirname "${BASH_SOURCE[0]}" )"

./build.sh --py-enable 1 --reqs-file /opencca/debos-fs/requirements.txt --format ext4 --imgsize 2300MB \
--console hvc0 --overlay-dest / --custom-script ./script.sh
