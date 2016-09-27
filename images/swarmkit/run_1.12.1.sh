#!/bin/bash -x

# Facts:
# 1. The leader (lowest create_index) is always a manager
# 2. Host labels are merely a visual aid (and useful for simple debugging)

META_URL="http://rancher-metadata.rancher.internal/2015-12-19"
SERVICE_NAME="swarm-mgr"

# This may be tuned for extra resilience - user should register at least this number of hosts
MANAGER_SCALE=3

AGENT_IP=$(curl -s ${META_URL}/self/host/agent_ip)
while [ "$AGENT_IP" == "" ]; do
  sleep 1
  AGENT_IP=$(curl -s ${META_URL}/self/host/agent_ip)
done

SERVICE_UUID=$(curl -s ${META_URL}/services/${SERVICE_NAME}/uuid)
HOST_UUID=$(curl -s ${META_URL}/self/host/uuid)

containers()           { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers);                    }
container_create_idx() { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/create_index);  }
container_svc_idx()    { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/service_index); }
container_host_uuid()  { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/host_uuid);     }
container_ip()         { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/primary_ip);    }

token() {
  token=$(curl -s ${META_URL}/services/${SERVICE_NAME}/metadata/${1})
  while [ "$token" == "Not found" ]; do
    sleep 1
    token=$(curl -s ${META_URL}/services/${SERVICE_NAME}/metadata/${1})
  done
  echo $token
}

manager_token() { echo $(token manager); }
worker_token()  { echo $(token worker);  }

get_leader() {
  local lowest_index
  local lowest_ip
  for container in $(containers); do
    c=$(echo $container | cut -d= -f2)
    create_index=$(container_create_idx $c)
    if [ "$lowest_index" == "" ] || [ "$create_index" -lt "$lowest_index" ]; then
      lowest_index=$create_index
      lowest_ip=$(container_ip $c)
    fi
  done
  echo $lowest_ip
}

get_service_index() {
  service_index=0
  for container in $(containers); do
    c=$(echo $container | cut -d= -f2)

    chost_uuid=$(container_host_uuid $c)
    if [ "$HOST_UUID" == "$chost_uuid" ]; then
      service_index=$(container_svc_idx $c)
      break
    fi
  done
  echo $service_index
}

is_swarm_manager()   { echo $(curl -s --unix-socket /var/run/docker.sock http::/info | jq -r .Swarm.ControlAvailable); }
local_node_state()   { echo $(curl -s --unix-socket /var/run/docker.sock http::/info | jq -r .Swarm.LocalNodeState);   }
get_swarm_node_id()  { echo $(curl -s --unix-socket /var/run/docker.sock http::/info | jq -r .Swarm.NodeID);           }
get_swarm_managers() { echo $(curl -s --unix-socket /var/run/docker.sock http::/info | jq -r .Swarm.Managers);         }
get_swarm_workers()  { echo $(curl -s --unix-socket /var/run/docker.sock http::/info | jq -r .Swarm.Workers);          }

publish_tokens() {
  SERVICE_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/services?uuid=${SERVICE_UUID}")
  PROJECT_ID=$(echo $SERVICE_DATA | jq -r '.data[0].accountId')
  SERVICE_ID=$(echo $SERVICE_DATA | jq -r '.data[0].id')
  SERVICE_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/projects/${PROJECT_ID}/services/${SERVICE_ID}")

  for type in worker manager; do
    token=$(docker swarm join-token $type -q)
    SERVICE_DATA=$(echo $SERVICE_DATA | jq -r ".metadata |= .+ {\"$type\":\"$token\"}")
  done

  curl -s -X PUT \
    -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "${SERVICE_DATA}" \
    "${CATTLE_URL}/projects/${PROJECT_ID}/services/${SERVICE_ID}"

  # validate that the write succeeded, retry if necessary
  SERVICE_DATA_CHANGED=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/services?uuid=${SERVICE_UUID}")
  if [ "$(echo $SERVICE_DATA_CHANGED | jq -r '.data[0].metadata.manager')" == "null" ]; then
    publish_tokens
  fi
}

publish_label() {
  local name=$1
  local value=$2

  HOST_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/hosts?uuid=${HOST_UUID}")
  PROJECT_ID=$(echo $HOST_DATA | jq -r '.data[0].accountId')
  HOST_ID=$(echo $HOST_DATA | jq -r '.data[0].id')
  HOST_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}")
  HOST_DATA=$(echo $HOST_DATA | jq -r ".labels |= .+ {\"$name\":\"$value\"}")

  curl -s -X PUT \
    -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "${HOST_DATA}" \
    "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}"

  # TODO validate that the write succeeded, retry if necessary
}

# promote/demote/delete nodes as necessary
reconcile_node() {
  # get current view of swarm nodes
  nodes=$(curl -s --unix-socket /var/run/docker.sock http::/nodes)

  # filter nodes based on healthy/role
  reachable_manager_nodes=$(echo $nodes | jq 'map(select(.Spec.Role == "manager")) | map(select(.ManagerStatus.Reachability == "reachable"))')
  unreachable_manager_nodes=$(echo $nodes | jq 'map(select(.Spec.Role == "manager")) | map(select(.ManagerStatus.Reachability == "unreachable"))')
  # ignore dead workers
  active_worker_nodes=$(echo $nodes | jq 'map(select(.Spec.Role == "worker")) | map(select(.Spec.Availability == "active"))')

  # count all nodes
  manager_reachable_count=$(echo $reachable_manager_nodes | jq length)
  manager_unreachable_count=$(echo $unreachable_manager_nodes | jq length)
  worker_node_count=$(echo $active_worker_nodes | jq length)

  # conditions for not performing reconciliation
  if [ "$manager_unreachable_count" -eq "0" ]; then
    echo "All $manager_reachable_count managers reachable."
    return
  elif [ "$manager_reachable_count" -le "$manager_unreachable_count" ]; then
    echo "Disaster scenario! Manual intervention required."
    return
  elif [ "$worker_node_count" -eq "0" ]; then
    echo "No workers present for promotion, add more nodes to restore resiliency."
    return
  fi

  echo "Detected $manager_reachable_count reachable and $manager_unreachable_count unreachable managers, $worker_node_count workers. Reconciling."

  # TODO choose the worker with lowest Rancher create_index to ensure leader is always a manager
  manager_id=$(echo $unreachable_manager_nodes | jq -r .[0].ID)
  worker_id=$(echo $active_worker_nodes | jq -r .[0].ID)

  # TODO promoted node should fix his host label
  docker node promote $worker_id
  docker node demote $manager_id
  docker node rm $manager_id
}

bootstrap_node() {
  # CATTLE_AGENT_IP will be the private IP in properly configured environments
  docker swarm init \
    --advertise-addr $AGENT_IP:2377

  # If we get this error back: must specify a listening address because the address
  # to advertise is not recognized as a system address
  # 
  # CATTLE_AGENT_IP is configured with public IPs...fall back to listening on eth0
  if [ "$?" != "0" ]; then
    docker swarm init \
      --advertise-addr $AGENT_IP:2377 \
      --listen-addr eth0:2377
  fi

  #giddyup probe tcp://${AGENT_IP}:2377 --loop --min 1s --max 5s --backoff 1.4

  publish_tokens
  publish_label swarm manager
}

runtime_node() {
  # TODO: For resiliency, loop through swarm=manager hosts instead of using LEADER_IP
  leader_ip=$(get_leader)
  giddyup probe tcp://${leader_ip}:2377 --loop --min 1s --max 4s --backoff 2 --num 4
  if [ "$?" != "0" ]; then
    exit 1
  fi

  # TODO: use containers with lowest create_index instead of lowest service_index
  if [ "$(get_service_index)" -le "$MANAGER_SCALE" ]; then
    docker swarm join --token $(manager_token) ${leader_ip}:2377
    publish_label swarm manager
  else
    docker swarm join --token $(worker_token) ${leader_ip}:2377
    publish_label swarm worker
  fi
}

node() {
  if [ -f /dr ]; then
    # Disaster recovery
    echo "Performing disaster recovery (unimplemented)"
    rm /dr

  # If we are the leader
  elif [ "$(get_leader)" == "$AGENT_IP" ]; then

    # Bootstrap a new 1-node manager cluster
    if [ "$(local_node_state)" == "inactive" ]; then
      bootstrap_node
    else
      reconcile_node
    fi
  # Scale up
  else
    runtime_node
  fi
}

while true; do
  node
  sleep 60
done
