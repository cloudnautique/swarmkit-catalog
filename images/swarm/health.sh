#!/bin/bash

if [ "$(curl -s --connect-timeout 10 --unix-socket /var/run/docker.sock http::/info | jq -r .Swarm.LocalNodeState)" == "active" ]; then
  exit 0
else
  exit 1
fi
