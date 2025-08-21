#!/bin/bash

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
mkdir -p $DIR/out
#debos --artifactdir $DIR \
 #    -t format:cpio -t cpioname:rootfs.cpio \
  #   -e CONSOLE:ttyS0 -e USERNAME:netsys -e PASSWORD:netsys -e SUDO_NOPASS:1 \
   #   $DIR/recipe.yaml

debos --artifactdir $DIR \
	-t format:cpio.gz -t cpioname_gz:rootfs.cpio.gz \
	-e CONSOLE:ttyS0 -e USERNAME:netsys -e PASSWORD:netsys -e SUDO_NOPASS:1 \
	$DIR/recipe.yaml

#debos --artifactdir $DIR \
 #     -t format:ext4 -t imgname:rootfs.img -t imgsize:500MB \
  #    -e CONSOLE:ttyS0 -e USERNAME:netsys -e PASSWORD:netsys -e SUDO_NOPASS:1 \
   #   $DIR/recipe.yaml
