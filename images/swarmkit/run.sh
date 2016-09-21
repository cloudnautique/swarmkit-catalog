#!/bin/sh -ex

SWARM_ELECTION_TICK=${SWARM_ELECTION_TICK:-3}
SWARM_ENGINE_ADDR=${SWARM_ENGINE_ADDR:-unix:///var/run/docker.sock}
SWARM_HEARTBEAT_TICK=${SWARM_HEARTBEAT_TICK:-1}
SWARM_HOSTNAME=${SWARM_HOSTNAME:-$(wget -q -O - http://rancher-metadata.rancher.internal/2015-12-19/self/host/hostname)}
SWARM_SOCKET=${SWARM_SOCKET:-/var/run/swarm.sock}
SWARM_DATA_DIR=${SWARM_DATA_DIR:-/etc/swarm}
SWARM_LOG_LEVEL=${SWARM_LOG_LEVEL:-info}

swarmd \
  --election-tick $SWARM_ELECTION_TICK \
  --engine-addr $SWARM_ENGINE_ADDR \
  --heartbeat-tick $SWARM_HEARTBEAT_TICK \
  --hostname $SWARM_HOSTNAME \
  --listen-control-api $SWARM_SOCKET \
  --log-level $SWARM_LOG_LEVEL \
  --state-dir $SWARM_DATA_DIR
