#!/bin/sh -ex

META_URL=http://rancher-metadata.rancher.internal/2015-12-19

SWARM_ELECTION_TICK=${SWARM_ELECTION_TICK:-3}
SWARM_ENGINE_ADDR=${SWARM_ENGINE_ADDR:-unix:///var/run/docker.sock}
SWARM_HEARTBEAT_TICK=${SWARM_HEARTBEAT_TICK:-1}
SWARM_HOSTNAME=${SWARM_HOSTNAME:-$(curl -s $META_URL/self/host/hostname)}
SWARM_REMOTE_API=${SWARM_REMOTE_API:-$(curl -s $META_URL/self/container/primary_ip):4242}
SWARM_SOCKET=${SWARM_SOCKET:-/var/run/swarm.sock}
SWARM_DATA_DIR=${SWARM_DATA_DIR:-/etc/swarm}
SWARM_LOG_LEVEL=${SWARM_LOG_LEVEL:-info}

publish_tokens() {
  giddyup probe tcp://${SWARM_REMOTE_API} --loop --min 1s --max 5s --backoff 1.4

  UUID=$(curl -s $META_URL/self/service/uuid)
  SERVICE_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/services?uuid=${UUID}")
  PROJECT_ID=$(echo $SERVICE_DATA | jq -r '.data[0].accountId')
  SERVICE_ID=$(echo $SERVICE_DATA | jq -r '.data[0].id')
  SERVICE_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/projects/${PROJECT_ID}/services/${SERVICE_ID}")

  for type in Worker Manager; do
    token=$(swarmctl cluster inspect default | grep $type | cut -d : -f 2)
    token=${token//[[:blank:]]/}
    SERVICE_DATA=$(echo $SERVICE_DATA | jq -r ".metadata |= .+ {\"$type\":\"$token\"}")
  done

  curl -s -X PUT \
    -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "${SERVICE_DATA}" \
    "${CATTLE_URL}/projects/$PROJECT_ID/services/${SERVICE_ID}"
}

standalone_node() {
  # TODO: add host label swarm:manager

  publish_tokens &

  swarmd \
    --election-tick $SWARM_ELECTION_TICK \
    --engine-addr $SWARM_ENGINE_ADDR \
    --heartbeat-tick $SWARM_HEARTBEAT_TICK \
    --hostname $SWARM_HOSTNAME \
    --listen-control-api $SWARM_SOCKET \
    --listen-remote-api $SWARM_REMOTE_API \
    --log-level $SWARM_LOG_LEVEL \
    --state-dir $SWARM_DATA_DIR
}


runtime_node() {
  # TODO: add host label swarm:worker
  JOIN_ADDR=$(giddyup leader get):4242
  JOIN_TOKEN=wat

  swarmd \
    --election-tick $SWARM_ELECTION_TICK \
    --engine-addr $SWARM_ENGINE_ADDR \
    --heartbeat-tick $SWARM_HEARTBEAT_TICK \
    --hostname $SWARM_HOSTNAME \
    --listen-control-api $SWARM_SOCKET \
    --listen-remote-api $SWARM_REMOTE_API \
    --log-level $SWARM_LOG_LEVEL \
    --state-dir $SWARM_DATA_DIR \
    --join-addr $JOIN_ADDR \
    --join-token $JOIN_TOKEN
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
