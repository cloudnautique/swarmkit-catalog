#!/bin/bash -x

# Facts:
# 1. The leader (lowest create_index) is always a manager
# 2. Host labels are merely a visual aid (and useful for simple debugging)

META_URL="http://rancher-metadata.rancher.internal/2015-12-19"
SERVICE_NAME="swarmkit-mon"

# This may be tuned for extra resilience - user should register at least this number of hosts
MANAGER_SCALE=${MANAGER_SCALE:-3}

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
  local lowest_index lowest_ip
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
    "${CATTLE_URL}/projects/${PROJECT_ID}/services/${SERVICE_ID}" &> /dev/null

  # validate that the write succeeded, retry if necessary
  SERVICE_DATA_CHANGED=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/services?uuid=${SERVICE_UUID}")
  if [ "$(echo $SERVICE_DATA_CHANGED | jq -r '.data[0].metadata.manager')" == "null" ]; then
    publish_tokens
  fi
}

get_label()            { curl -s "${META_URL}/self/host/labels/${1}"; }

set_label() {
  local name=$1 value=$2

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
    "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}" &> /dev/null

  echo "Set host label $name=$value"
}

del_label() {
  local name=$1

  HOST_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/hosts?uuid=${HOST_UUID}")
  PROJECT_ID=$(echo $HOST_DATA | jq -r '.data[0].accountId')
  HOST_ID=$(echo $HOST_DATA | jq -r '.data[0].id')
  HOST_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}")
  HOST_DATA=$(echo $HOST_DATA | jq 'del(.labels.swarm)')

  curl -s -X PUT \
    -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "${HOST_DATA}" \
    "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}" &> /dev/null

  echo "Deleted host label $name"
}

reconcile_label() {
  label=$(get_label swarm)
  manager=$(is_swarm_manager)

  if [ "$manager" == "true" ] && [ "$label" != "manager" ]; then
    set_label swarm manager
  elif [ "$manager" == "false" ] && [ "$label" == "Not Found" ]; then
    del_label swarm
  fi
}

# when a host is removed from a Rancher environment, remove it from the swarm
remove_old_hosts() {
  nodes=$(curl -s --unix-socket /var/run/docker.sock http::/nodes)
  hosts=$(curl -s -H 'Accept:application/json' ${META_URL}/hosts)
  for hostname in $(echo $hosts | jq -r .[].hostname); do
    # filter out the hostnames in Rancher metadata
    nodes=$(echo $nodes | jq "map(select(.Description.Hostname!=\"$hostname\"))")
  done

  # remaining nodes are not in an environment and should be removed
  for hostname in $(echo $nodes | jq -r .[].Description.Hostname); do
    id=$(echo $nodes | jq -r "map(select(.Description.Hostname==\"$hostname\")) | .[0].ID")
    role=$(echo $nodes | jq -r "map(select(.Description.Hostname==\"$hostname\")) | .[0].Spec.Role")
    if [ "$role" == "manager" ]; then
      docker node demote $id
    fi
    docker node rm $id --force
    echo Removed $id from the swarm.
  done
}

reconcile_node() {
  remove_old_hosts

  # get current view of swarm nodes
  nodes=$(curl -s --unix-socket /var/run/docker.sock http::/nodes)

  # filter nodes based on healthy/role
  reachable_manager_nodes=$(echo $nodes | jq 'map(select(.Spec.Role == "manager")) | map(select(.ManagerStatus.Reachability == "reachable"))')
  unreachable_manager_nodes=$(echo $nodes | jq 'map(select(.Spec.Role == "manager")) | map(select(.ManagerStatus.Reachability == "unreachable"))')
  # active workers
  active_worker_nodes=$(echo $nodes | jq 'map(select(.Spec.Role == "worker")) | map(select(.Spec.Availability == "active"))')

  # count all nodes
  node_count=$(echo $nodes | jq length)
  manager_reachable_count=$(echo $reachable_manager_nodes | jq length)
  manager_unreachable_count=$(echo $unreachable_manager_nodes | jq length)
  manager_count=$(($manager_reachable_count + $manager_unreachable_count))
  worker_node_count=$(echo $active_worker_nodes | jq length)

  echo "$manager_reachable_count of $manager_count manager(s) reachable, $worker_node_count worker(s) active"

  # conditions for not performing reconciliations
  if [ "$manager_reachable_count" -le "$manager_unreachable_count" ]; then
    echo "ERROR: Majority managers lost. Manual intervention required."
    return
  elif [ "$manager_unreachable_count" -eq "0" ] && [ "$manager_reachable_count" -ge "$MANAGER_SCALE" ]; then
    return
  elif [ "$worker_node_count" -eq "0" ]; then
    echo "No active workers present for promotion, add more nodes to enable reconciliation."
    return
  elif [ "$node_count" -lt "$MANAGER_SCALE" ]; then
    echo "WARNING: Only $node_count nodes available, need >= $MANAGER_SCALE nodes to acheive resiliency guarantees!"
  fi

  # demote/delete an unreachable manager
  if [ "$manager_unreachable_count" -gt "0" ]; then
    manager_id=$(echo $unreachable_manager_nodes | jq -r .[0].ID)
    docker node demote $manager_id
    docker node rm $manager_id
    echo Removed $manager_id from the swarm.
  fi

  # promote a worker
  # TODO choose the worker with lowest Rancher create_index to ensure leader is always a manager..otherwise we might elect a non-manager for reconciliation
  worker_id=$(echo $active_worker_nodes | jq -r .[0].ID)
  docker node promote $worker_id

  # refresh view of swarm nodes
  nodes=$(curl -s --unix-socket /var/run/docker.sock http::/nodes)

  # delete down nodes that were replaced (perhaps user manually intervened?)
  for hostname in $(echo $nodes | jq -r 'map(select(.Status.State=="down"))  | .[].Description.Hostname'); do
    if [ "$(echo $nodes | jq 'map(select(.Status.State=="ready")) | map(select(.Description.Hostname=="$hostname")) | .[0].ID')" != "" ]; then
      id=$(echo $nodes | jq -r "map(select(.Status.State==\"down\"))  | map(select(.Description.Hostname==\"$hostname\")) | .[0].ID")
      echo $hostname has a dead node with id $id we can safely delete
      docker node demote $id
      docker node rm $id
    fi
  done
}

# Bootstrap a new 1-node manager cluster
bootstrap_node() {
  if [ "$LISTEN_INTERFACE" == "" ]; then
    docker swarm init
  else
    docker swarm init \
      --advertise-addr ${AGENT_IP}:2377 \
      --listen-addr ${LISTEN_INTERFACE}:2377
  fi

  publish_tokens
  set_label swarm manager
}

runtime_node() {
  # TODO For resiliency, we might want to loop through swarm=manager hosts instead of requiring the leader
  local leader_ip=$(get_leader)
  giddyup probe tcp://${leader_ip}:2377 --loop --min 1s --max 4s --backoff 2 --num 4 &> /dev/null
  if [ "$?" != "0" ]; then
    exit 1
  fi

  # use containers with lowest create_index as managers
  should_be_manager=$(curl -s -H 'Accept:application/json' ${META_URL}/services/${SERVICE_NAME}/containers \
   | jq "sort_by(.create_index) | .[0:$MANAGER_SCALE]  | map(select(.host_uuid==\"$HOST_UUID\")) | length")

  local token
  if [ "$should_be_manager" -eq "1" ]; then
    token=$(manager_token)
  else
    token=$(worker_token)
  fi

  if [ "$LISTEN_INTERFACE" == "" ]; then
    # let swarm try to detect the interface
    docker swarm join \
      --token $token \
        ${leader_ip}:2377
  else
    docker swarm join \
      --token $token \
      --advertise-addr ${AGENT_IP}:2377 \
      --listen-addr ${LISTEN_INTERFACE}:2377 \
        ${leader_ip}:2377
  fi

  if [ "$should_be_manager" -eq "1" ]; then
    set_label swarm manager
  fi
}

node() {
  if [ "$(get_leader)" == "$AGENT_IP" ]; then

    if [ "$(local_node_state)" == "inactive" ]; then
      bootstrap_node

    else
      reconcile_node
    fi

  elif [ "$(local_node_state)" == "inactive" ]; then
    runtime_node
  else
    reconcile_label
  fi

}

giddyup health -p 2378 --check-command /opt/rancher/health.sh &
while true; do
  node
  sleep 30
done
