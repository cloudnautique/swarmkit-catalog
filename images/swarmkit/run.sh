#!/bin/bash -x

# Determine Docker server version
version=$(docker version|grep Version|head -n1|cut -d: -f2|tr -d '[[:space:]]')

# Update symlink
ln -fs /usr/bin/docker-$version /usr/bin/docker

# Run appropriate script
exec /run_$version.sh
