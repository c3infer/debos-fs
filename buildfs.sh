#!/bin/bash 

cd "$( dirname "${BASH_SOURCE[0]}" )"

IMG_SIZE="${IMG_SIZE:-5000MB}"
DEBOS_MEMORY="${DEBOS_MEMORY:-8Gb}"

./build.sh --py-enable 1 --reqs-file /opencca/debos-fs/requirements.txt --format ext4 --imgsize "${IMG_SIZE}" \
--memory "${DEBOS_MEMORY}" --console hvc0 --overlay-dest / --custom-script ./script.sh
