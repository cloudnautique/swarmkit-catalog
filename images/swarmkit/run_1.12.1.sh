#!/bin/bash -x

export META_URL="http://rancher-metadata.rancher.internal/2015-12-19"
giddyup service wait scale

SERVICE_NAME=swarm-mgr
AGENT_IP=$(curl -s ${META_URL}/self/host/agent_ip)
SERVICE_UUID=$(curl -s $META_URL/services/${SERVICE_NAME}/uuid)
container_ip()       { curl -s ${META_URL}/self/service/containers/${1}/primary_ip    }
container_svc_idx()  { curl -s ${META_URL}/self/service/containers/${1}/service_index }
container_hostname() { curl -s ${META_URL}/self/service/containers/${1}/hostname      }

is_swarm_manager()
{
    active=false
    if docker -H tcp://${1}:2375 info 2>&1|grep Is\ Manager\:\ true> /dev/null ; then
        active="true"
    fi

    echo ${active}
}

# returns: 'active' or 'inactive'
local_node_state() {
  node_state localhost
}

node_state()
{
  echo $(curl -s http://${1}:2375/info | jq -r .Swarm.LocalNodeState)
}

get_manager_swarm_ip()
{
    echo $(docker swarm join-token worker | tail -1 | awk '{gsub(/^[ \t]+/,"",$0); split($0,a,":"); print a[1]}')
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
}

get_manager_ip()
{
    for container in $(giddyup service containers -n); do
        svc_index="$(curl -s -H 'Accept: application/json' ${META_URL}/self/service/containers/${container} | jq -r '.service_index')"
        ip=$(container_ip $container)

        if [ "$(is_swarm_manager ${ip})" = "true"  ]; then
            echo "${ip}"
            return 
        fi
    done
}

manager_secret()
{
    echo $(docker -H tcp://$(get_manager_ip):2375 swarm join-token manager|grep token|awk '{print $2}')
}

worker_secret()
{
    echo $(docker -H tcp://$(get_manager_ip):2375 swarm join-token worker|grep token|awk '{print $2}')
}

demote_node()
{
    mgr_ip=$(get_manager_ip)
    if [ ! -z ${mgr_ip} ]; then
        docker -H tcp://${mgr_ip}:2375 node demote ${1}
    fi
}

promote_node()
{
    mgr_ip=$(get_manager_ip)
    if [ ! -z ${mgr_ip} ]; then
        docker -H tcp://${mgr_ip}:2375 node promote ${1}
    fi
}

get_swarm_node_id()
{
    echo $(docker -H tcp://${1}:2375 info 2>&1|grep NodeID|cut -d':' -f2|tr -d '[[:space:]]')
}

is_swarm_manager()
{
    manager=false
    if docker -H tcp://${1}:2375 info 2>&1|grep IsManager\:\ Yes > /dev/null ; then
        manager="true"
    fi

    echo ${manager}
}

add_worker()
{
    LEADER_DOCKER_IP=$(get_manager_ip)
    LEADER_IP=$(get_manager_swarm_ip ${LEADER_DOCKER_IP})
    if [ "$(node_state ${1})" = "active" ] && [ "$(is_swarm_manager ${1})" = "true" ]; then 
            demote_node $(get_swarm_node_id ${1})
    fi

    if [ "$(node_state ${1})" = "inactive" ]; then
        docker -H tcp://${1}:2375 swarm join --token $(worker_secret) ${LEADER_IP}:2377
    fi
}

publish_tokens() {
  giddyup probe tcp://$AGENT_IP:2377 --loop --min 1s --max 5s --backoff 1.4

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
    "${CATTLE_URL}/projects/$PROJECT_ID/services/${SERVICE_ID}"
}


add_manager()
{
    LEADER_DOCKER_IP=$(get_manager_ip)
    LEADER_IP=$(get_manager_swarm_ip ${LEADER_DOCKER_IP})
    if [ "$(node_state ${1})" = "active" ] && [ "$(is_swarm_manager ${1})" = "false" ]; then 
            promote_node $(get_swarm_node_id ${1})
    fi

    if [ "$(node_state ${1})" = "inactive" ];then
        docker -H tcp://${1}:2375 swarm join --token $(manager_secret) ${LEADER_IP}:2377
    fi
}

while true; do
  if giddyup leader check; then
    # Bootstrap a new 1-node manager cluster
    if [ "$(local_node_state)" = "inactive" ]; then
      # CATTLE_AGENT_IP will be the private IP in properly configured environments
      docker swarm init --advertise-addr $AGENT_IP:2377

      publish_tokens
      # publish registration tokens to metadata (can use vault later)
      docker swarm join-token manager -q
      docker swarm join-token worker -q
    fi
   
    # reconcile_state
    for c in $(giddyup service containers -n); do
      svc_idx=$(container_svc_idx $c)
      if [ "${svc_idx}" -le "3" ]; then 
        add_manager $(container_ip $c)
      else
        add_worker $(container_ip $c)
      fi     
    done
  fi
  sleep 60
done
