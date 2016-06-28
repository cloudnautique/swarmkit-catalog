#!/bin/bash

set -x

export DOCKER_SWARM_SECRET=$(curl -s http://rancher-metadata.rancher.internal/2015-12-19/self/service/uuid)
export SVC_INDEX=$(curl -s http://rancher-metadata.rancher.internal/2015-12-19/self/container/service_index)
/giddyup service wait scale
export LEADER_IP=$(/giddyup leader get agent_ip)

join()
{
    while true; do
        docker -H tcp://$(/giddyup leader get):2375 ps
        if [ "$?" -eq "0" ]; then
            break
        fi
        sleep 1
    done

    if [ "${SVC_INDEX}" -gt "3" ]; then
        docker swarm join --secret ${DOCKER_SWARM_SECRET} ${LEADER_IP}:2377
    else
        docker swarm join --manager --secret ${DOCKER_SWARM_SECRET} ${LEADER_IP}:2377
    fi
}

swarm_exists()
{
    exists="false"
    docker swarm inspect >/dev/null 2>&1
    if [ "$?" -eq "0" ]; then
        exists="true"
    fi

    echo ${exists}
}

is_swarm_member()
{
    active=false
    docker info 2>&1|grep Swarm\:\ active > /dev/null
    if [ "$?" -eq "0" ]; then
        active="true"
    fi

    echo ${active}
}

is_swarm_manager()
{
    manager=false
    docker info 2>&1|grep IsManager\:\ Yes > /dev/null
    if [ "$?" -eq "0" ]; then
        manager="true"
    fi

    echo ${manager}
}

bootstrap()
{
    /giddyup leader check
    if [ "$?" -eq "0" ]; then
        if [ "$(swarm_exists)" = "false" ]; then
            docker swarm init --auto-accept worker --auto-accept manager --secret ${DOCKER_SWARM_SECRET} 
        fi
    else
        join
    fi
}

demote_node()
{
    docker node demote -f ${1}
}

if [ "$(is_swarm_member)" = "true" ]; then
    if [ "$(is_swarm_manager)" = "true" ]; then
      if [ "${SVC_INDEX}" -gt "3" ]; then
          demote_node $(docker info 2>&1|grep NodeID|cut -d':' -f2|tr -d '[[:space:]]')
      fi
    fi
else
    bootstrap
fi

exec socat -d -d TCP-L:2375,fork UNIX:/var/run/docker.sock
