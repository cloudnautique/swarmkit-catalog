#!/bin/sh -ex

SWARM_ELECTION_TICK=${SWARM_ELECTION_TICK:-3}
SWARM_ENGINE_ADDR=${SWARM_ENGINE_ADDR:-unix:///var/run/docker.sock}
SWARM_HEARTBEAT_TICK=${SWARM_HEARTBEAT_TICK:-1}
SWARM_HOSTNAME=${SWARM_HOSTNAME:-$(wget -q -O - http://rancher-metadata.rancher.internal/2015-12-19/self/host/hostname)}
SWARM_SOCKET=${SWARM_SOCKET:-/var/run/swarm.sock}
SWARM_DATA_DIR=${SWARM_DATA_DIR:-/etc/swarm}
SWARM_LOG_LEVEL=${SWARM_LOG_LEVEL:-info}

standalone_node() {
  # TODO: add host label swarm:manager

  swarmd \
    --election-tick $SWARM_ELECTION_TICK \
    --engine-addr $SWARM_ENGINE_ADDR \
    --heartbeat-tick $SWARM_HEARTBEAT_TICK \
    --hostname $SWARM_HOSTNAME \
    --listen-control-api $SWARM_SOCKET \
    --log-level $SWARM_LOG_LEVEL \
    --state-dir $SWARM_DATA_DIR
}

runtime_node() {
  # TODO: add host label swarm:worker

  swarmd \
    --election-tick $SWARM_ELECTION_TICK \
    --engine-addr $SWARM_ENGINE_ADDR \
    --heartbeat-tick $SWARM_HEARTBEAT_TICK \
    --hostname $SWARM_HOSTNAME \
    --listen-control-api $SWARM_SOCKET \
    --log-level $SWARM_LOG_LEVEL \
    --state-dir $SWARM_DATA_DIR
    #--join-addr 127.0.0.1:4242 \
    #--join-token "<Worker Token>"
}

rancher_node() {
  if giddyup leader check; then
    standalone_node
  else
    runtime_node
  fi
}

if [ $# -eq 0 ]; then
    echo No command specified, running in standalone mode.
    standalone_node
else
    eval $1
fi
