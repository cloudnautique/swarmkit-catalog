#!/bin/bash -x

META_URL="http://rancher-metadata.rancher.internal/2015-12-19"
SERVICE_NAME="swarm-mgr"

AGENT_IP=$(curl -s ${META_URL}/self/host/agent_ip)
SERVICE_UUID=$(curl -s ${META_URL}/services/${SERVICE_NAME}/uuid)
HOST_UUID=$(curl -s ${META_URL}/self/host/uuid)

# don't work
container_svc_idx()  { echo $(curl -s ${META_URL}/self/service/containers/${1}/service_index); }
container_hostname() { echo $(curl -s ${META_URL}/self/service/containers/${1}/hostname);      }

containers()           { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers);                   }
container_create_idx() { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/create_index); }
container_ip()         { echo $(curl -s ${META_URL}/services/${SERVICE_NAME}/containers/${1}/primary_ip);   }

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

# compute this up front - once and only once
LEADER_IP=$(get_leader)

#is_swarm_manager() {
#    active=false
#    if docker -H tcp://${1}:2375 info 2>&1|grep Is\ Manager\:\ true> /dev/null ; then
#        active="true"
#    fi

#    echo ${active}
#}

# TODO: remove dependency on this so we can remove socat
node_state() {
  echo $(curl -s http://${1}:2375/info | jq -r .Swarm.LocalNodeState)
}

local_node_state() {
  echo $(node_state localhost)
}

#get_manager_swarm_ip() {
#    echo $(docker swarm join-token worker | tail -1 | awk '{gsub(/^[ \t]+/,"",$0); split($0,a,":"); print a[1]}')
    # for container in $(giddyup service containers -n); do
        # ip=$(container_ip $container)
        # 
        # if [ "$(is_swarm_manager ${ip})" = "true"  ]; then
            # UUID=$(curl -s -H 'Accept: application/json' ${META_URL}/self/service/containers/${container}|jq -r '.host_uuid')
        # IP=$(curl -s -H 'Accept: application/json' ${META_URL}/hosts |jq -r ".[] | select(.uuid==\"${UUID}\") | .agent_ip")
        # echo ${IP}
            # return 
        # fi
    # done
#}

#get_manager_ip() {
#    for container in $(giddyup service containers -n); do
#        svc_index="$(curl -s -H 'Accept: application/json' ${META_URL}/self/service/containers/${container} | jq -r '.service_index')"
#        ip=$(container_ip $container)

#        if [ "$(is_swarm_manager ${ip})" = "true"  ]; then
#            echo "${ip}"
#            return 
#        fi
#    done
#}

#demote_node() {
#    mgr_ip=$(get_manager_ip)
#    if [ ! -z ${mgr_ip} ]; then
#        docker -H tcp://${mgr_ip}:2375 node demote ${1}
#    fi
#}

#promote_node() {
#    mgr_ip=$(get_manager_ip)
#    if [ ! -z ${mgr_ip} ]; then
#        docker -H tcp://${mgr_ip}:2375 node promote ${1}
#    fi
#}

#get_swarm_node_id() {
#  echo $(docker -H tcp://${1}:2375 info 2>&1|grep NodeID|cut -d':' -f2|tr -d '[[:space:]]')
#}

#add_worker() {
#    LEADER_DOCKER_IP=$(get_manager_ip)
#    LEADER_IP=$(get_manager_swarm_ip ${LEADER_DOCKER_IP})
#    if [ "$(node_state ${1})" = "active" ] && [ "$(is_swarm_manager ${1})" = "true" ]; then 
#            demote_node $(get_swarm_node_id ${1})
#    fi

#    if [ "$(node_state ${1})" = "inactive" ]; then
#        docker -H tcp://${1}:2375 swarm join --token $(worker_token) ${LEADER_IP}:2377
#    fi
#}

#add_manager() {
#    LEADER_DOCKER_IP=$(get_manager_ip)
#    LEADER_IP=$(get_manager_swarm_ip ${LEADER_DOCKER_IP})
#    if [ "$(node_state ${1})" = "active" ] && [ "$(is_swarm_manager ${1})" = "false" ]; then 
#            promote_node $(get_swarm_node_id ${1})
#    fi
#
#    if [ "$(node_state ${1})" = "inactive" ]; then
#        docker -H tcp://${1}:2375 swarm join --token $(manager_token) ${LEADER_IP}:2377
#    fi
#}

publish_tokens() {
  giddyup probe tcp://${AGENT_IP}:2377 --loop --min 1s --max 5s --backoff 1.4

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
}

publish_type() {
  local nodetype=$1

  HOST_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/hosts?uuid=${HOST_UUID}")
  PROJECT_ID=$(echo $HOST_DATA | jq -r '.data[0].accountId')
  HOST_ID=$(echo $HOST_DATA | jq -r '.data[0].id')
  HOST_DATA=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}")
  HOST_DATA=$(echo $HOST_DATA | jq -r ".labels |= .+ {\"swarm\":\"$nodetype\"}")

  curl -s -X PUT \
    -u "${CATTLE_ACCESS_KEY}:${CATTLE_SECRET_KEY}" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "${HOST_DATA}" \
    "${CATTLE_URL}/projects/${PROJECT_ID}/hosts/${HOST_ID}"
}

standalone_node() {
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

  publish_tokens
  publish_type manager
}

runtime_node() {
  # TODO: For resilience, loop through swarm=manager hosts (use --num X)
  giddyup probe tcp://${LEADER_IP}:2377 --loop --min 1s --max 4s --backoff 2

  # TODO: switch to workers after 7ish managers (raft gets chatty)
  # TODO: use lowest create_index containers as managers and promote/demote as necessary to maintain

  docker swarm join --token $(manager_token) $LEADER_IP:2377
  publish_type manager
}

node() {
  if [ -f /dr ]; then
    # Disaster recovery
    echo Performing disaster recovery (unimplemented)
    rm /dr

  elif [ "$(local_node_state)" == "active" ]; then
    echo "Swarm node already active."

  # Bootstrap a new 1-node manager cluster
  elif [ "$LEADER_IP" == "$AGENT_IP" ]; then
    standalone_node
   
    # reconcile_state
    #for c in $(giddyup service containers -n); do
    #  svc_idx=$(container_svc_idx $c)
    #  if [ "${svc_idx}" -le "3" ]; then 
    #    add_manager $(container_ip $c)
    #  else
    #    add_worker $(container_ip $c)
    #  fi     
    #done

  # Scale up
  else
    runtime_node
  fi
}

while true; do
  node
  sleep 60
done
