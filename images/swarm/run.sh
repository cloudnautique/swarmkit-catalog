#!/bin/bash

unsupported_version() {
  local version="v${1}"
  echo "Docker $version is unsupported, please install v1.12.1 or later" 1>&2
  exit 1
}

# ensure valid Docker server version
validate_docker_version() {
  local version=$(docker version|grep Version|head -n1|cut -d: -f2|tr -d '[[:space:]]')
  case "$version" in
    1.13.* ) ;;
    * )      unsupported_version $version;;
  esac
}

common() {
  META_URL="http://rancher-metadata.rancher.internal/2015-12-19"
  META_NOT_FOUND="Not found"
  SERVICE_NAME="swarmkit-mon"
  SERVICE_UUID=$(curl -s ${META_URL}/services/${SERVICE_NAME}/uuid)
  HOST_UUID=$(curl -s ${META_URL}/self/host/uuid)
  # This may be tuned for extra resilience - user should register at least this number of hosts
  MANAGER_SCALE=${MANAGER_SCALE:-3}
}

# this blocks until rancher metadata is available
update_agent_ip() {
  while true; do
    AGENT_IP=$(curl -s ${META_URL}/self/host/agent_ip)
    if [ "$AGENT_IP" == "" ]; then
      sleep 1
      continue
    else
      break
    fi
  done
}

containers()           { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers);                    }
container_create_idx() { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/create_index);  }
container_svc_idx()    { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/service_index); }
container_host_uuid()  { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/host_uuid);     }
container_ip()         { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/primary_ip);    }
metadata_value()       { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/metadata/${1});                 }

wait_metadata_value() {
  local metadata_key=$1
  local token="$META_NOT_FOUND"
  while [ "$token" == "$META_NOT_FOUND" ]; do
    sleep 1
    token=$(metadata_value $metadata_key)
  done
  echo $token
}

wait_manager_token() { echo $(wait_metadata_value manager); }
wait_worker_token()  { echo $(wait_metadata_value worker);  }

update_leader_ip() {
  local lowest_index
  for container in $(containers); do
    c=$(echo $container | cut -d= -f2)
    create_index=$(container_create_idx $c)
    if [ "$lowest_index" == "" ] || [ "$create_index" -lt "$lowest_index" ]; then
      lowest_index=$create_index
      LEADER_IP=$(container_ip $c)
    fi
  done
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

update_docker_nodes() { DOCKER_NODES="$(curl -s --unix-socket /var/run/docker.sock http::/nodes)"; }
update_docker_info()  {  DOCKER_INFO="$(curl -s --unix-socket /var/run/docker.sock http::/info)";  }

get_docker_nodes() { [ "$DOCKER_NODES" ] || update_docker_nodes; echo $DOCKER_NODES; }
get_swarm_member() { echo $DOCKER_INFO | jq -r .Swarm.${1}; }

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
    echo "Retrying publishing tokens"
    publish_tokens
  else
    echo "Set swarm join-tokens"
  fi
}

get_label()            { curl -s "${META_URL}/self/host/labels/${1}"; }

set_label() {
  local name=$1 value=$2 tries=$3
  if [ "$tries" == "" ]; then
    tries=1
  fi

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

  # validate that the write succeeded, retry if necessary
  HOST_DATA_CHANGED=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}")
  new_value=$(echo $HOST_DATA_CHANGED | jq -r ".labels.$name")
  if [ "$new_value" != "$value" ]; then
    if [ "$tries" == "5" ]; then
      echo "Failed to set host label $name=$value ($tries tries)"  1>&2
      exit 1
    else
      echo "Retrying set host label $name=$value" 1>&2
      sleep 0.5
      set_label $name $value $(($tries + 1))
    fi
  else
    echo "Set host label $name=$value"
  fi
}

del_label() {
  local name=$1

  HOST_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/hosts?uuid=${HOST_UUID}")
  PROJECT_ID=$(echo $HOST_DATA | jq -r '.data[0].accountId')
  HOST_ID=$(echo $HOST_DATA | jq -r '.data[0].id')
  HOST_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}")
  HOST_DATA=$(echo $HOST_DATA | jq "del(.labels.$name)")

  curl -s -X PUT \
    -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "${HOST_DATA}" \
    "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}" &> /dev/null

  # validate that the write succeeded, retry if necessary
  HOST_DATA_CHANGED=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}")
  new_value=$(echo $HOST_DATA_CHANGED | jq -r ".labels.$name")
  if [ "$new_value" != "null" ]; then
    echo "Retrying delete host label $name"
    del_label $name
    sleep 0.5
  else
    echo "Deleted host label $name"
  fi
}

reconcile_label() {
  label=$(get_label swarm)
  update_docker_info
  manager=$(get_swarm_member ControlAvailable)

  if [ "$manager" == "true" ] && [ "$label" != "manager" ]; then
    set_label swarm manager
  elif [ "$manager" == "false" ] && [ "$label" != "Not found" ]; then
    del_label swarm
  fi
}

# when a host is removed from a Rancher environment, remove it from the swarm
remove_old_hosts() {
  update_docker_nodes
  nodes=$(get_docker_nodes)
  hosts=$(curl -s -H 'Accept:application/json' ${META_URL}/hosts)
  for hostname in $(echo $hosts | jq -r .[].hostname | cut -d. -f1); do
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
  update_docker_nodes
  nodes=$(get_docker_nodes)

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

  # demote/delete an unreachable manager
  if [ "$manager_unreachable_count" -gt "0" ]; then
    manager_id=$(echo $unreachable_manager_nodes | jq -r .[0].ID)
    docker node demote $manager_id
    docker node rm $manager_id
    echo Removed $manager_id from the swarm.
  fi

  # refresh view of swarm nodes
  update_docker_nodes
  nodes=$(get_docker_nodes)

  # delete down nodes that were replaced (perhaps user manually intervened?)
  for hostname in $(echo $nodes | jq -r 'map(select(.Status.State=="down"))  | .[].Description.Hostname'); do
    if [ "$(echo $nodes | jq 'map(select(.Status.State=="ready")) | map(select(.Description.Hostname=="$hostname")) | .[0].ID')" != "" ]; then
      id=$(echo $nodes | jq -r "map(select(.Status.State==\"down\"))  | map(select(.Description.Hostname==\"$hostname\")) | .[0].ID")
      echo $hostname has a dead node with id $id we can safely delete
      docker node ls
      docker node demote $id
      docker node rm $id
    fi
  done

  # conditions for not performing reconciliations
  if [ "$manager_reachable_count" -le "$manager_unreachable_count" ]; then
    echo "ERROR: Majority managers lost. Manual intervention required."
    return
  elif [ "$manager_unreachable_count" -eq "0" ] && [ "$manager_reachable_count" -eq "$MANAGER_SCALE" ]; then
    return
  fi

  # promote a worker
  if [ "$manager_reachable_count" -lt "$MANAGER_SCALE" ]; then
    if [ "$worker_node_count" -gt "0" ]; then
      # TODO choose the worker with lowest Rancher create_index to ensure leader is always a manager..otherwise we might elect a non-manager for reconciliation
      worker_id=$(echo $active_worker_nodes | jq -r .[0].ID)
      docker node promote $worker_id
    else
      echo "No active workers present for promotion, add more nodes to enable reconciliation."
    fi
  # demote a manager
  elif [ "$manager_reachable_count" -gt "$MANAGER_SCALE" ]; then
    # TODO choose the manager with highest Rancher create_index to ensure leader is always a manager...
    manager_id=$(echo $reachable_manager_nodes | jq -r .[0].ID)
    docker node demote $manager_id
  fi
}

# Bootstrap a new 1-node manager cluster
bootstrap_node() {
  set -x
  docker swarm init \
    --advertise-addr ${AGENT_IP}:2377
  set +x

  echo $(docker swarm join-token worker -q) > /var/lib/rancher/state/.swarm_token

  if [ "$?" != "0" ]; then
    set_label swarm failed
  else
    publish_tokens
    set_label swarm manager
  fi
}

runtime_node() {
  set_label swarm wait_leader
  # TODO For resiliency, we might want to loop through swarm=manager hosts instead of requiring the leader
  giddyup probe tcp://${LEADER_IP}:2377 --loop --min 1s --max 4s --backoff 2 --num 4 &> /dev/null
  if [ "$?" != "0" ]; then
    exit 1
  fi

  # use containers with lowest create_index as managers
  should_be_manager=$(curl -s -H 'Accept:application/json' ${META_URL}/services/${SERVICE_NAME}/containers \
   | jq "sort_by(.create_index) | .[0:$MANAGER_SCALE]  | map(select(.host_uuid==\"$HOST_UUID\")) | length")

  set_label swarm wait_token
  local worker_token=$(wait_worker_token)
  local manager_token=$(wait_manager_token)

  local token
  if [ "$should_be_manager" -eq "1" ]; then
    token=$manager_token
  else
    token=$worker_token
  fi

  set -x
  docker swarm join \
    --token $token \
    --advertise-addr ${AGENT_IP}:2377 \
      ${LEADER_IP}:2377
  set +x

  # save state of swarm by persisting token to the host
  echo $worker_token > /var/lib/rancher/state/.swarm_token

  if [ "$?" != "0" ]; then
    set_label swarm failed
  elif [ "$should_be_manager" -eq "1" ]; then
    set_label swarm manager
  else
    del_label swarm
  fi
}

node() {
  update_docker_info
  local state=$(get_swarm_member LocalNodeState)
  local error=$(get_swarm_member Error)

  if [ "$error" != "" ]; then
    echo $error
    leave_swarm
  fi
  # if the swarm address no longer matches the agent IP address
  #if [ "$AGENT_IP" != "$(get_swarm_member NodeAddr)" ]; then
  #  leave_swarm
  #fi

  update_leader_ip
  update_agent_ip
  if [ "$LEADER_IP" == "$AGENT_IP" ]; then

    if [ "$state" == "inactive" ]; then
      bootstrap_node
    else
      reconcile_node
    fi

  elif [ "$state" == "inactive" ]; then
    runtime_node
  fi
  
  reconcile_label
}

leave_swarm() {
  set_label swarm wait_leaving
  echo Leaving old swarm

  docker swarm leave --force

  if [ "$?" != "0" ]; then
    set_label swarm deadlock
    echo Deadlocked trying to leave swarm. Please restart Docker daemon.
    sleep 300
    exit 1
  else
    del_label swarm
  fi
}

main() {
  validate_docker_version
  common
  update_agent_ip
  update_docker_info
  
  local state=$(get_swarm_member LocalNodeState)
  # detect if host is participating in an old swarm that doesn't match the Rancher stack
  if [ "$state" != "inactive" ]; then
    if [ -f "/var/lib/rancher/state/.swarm_token" ]; then
      local old_token=$(cat /var/lib/rancher/state/.swarm_token)
    fi
    local cur_token=$(metadata_value worker)
    # if host's state (token) doesn't match this stack's state (token), leave
    if [ "$old_token" != "$cur_token" ]; then
      echo "    Old token: $old_token"
      echo "Current token: $cur_token"
      leave_swarm
    fi
  fi

  # wait until port is available (previous stack could still be stopping)
  while [ "$(giddyup probe tcp://localhost:2378)" == "OK" ]; do
    sleep 3
  done
  giddyup health -p 2378 --check-command /opt/rancher/health.sh &

  while true; do
    node
    sleep 30
  done
}

main "$@"
