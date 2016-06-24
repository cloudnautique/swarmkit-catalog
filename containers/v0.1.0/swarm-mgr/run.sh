#!/bin/bash

set -x

export DOCKER_SWARM_SECRET=$(curl -s http://rancher-metadata.rancher.internal/2015-12-19/self/service/uuid)
export SVC_INDEX=$(curl -s http://rancher-metadata.rancher.internal/2015-12-19/self/container/service_index)
/giddyup service wait scale
export LEADER_IP=$(/giddyup leader get agent_ip)

join()
{
    LEADER_SOCKET=
    while true; do
        docker -H tcp://$(/giddyup leader get):2375 ps
        if [ "$?" -eq "0" ]; then
            break
        fi
        sleep 1
    done

    if [ "${SVC_INDEX}" -gt "3" ]; then
        #docker swarm join --secret ${DOCKER_SWARM_SECRET} $(docker -H tcp://$(/giddyup leader get):2375 node ls|grep Yes|awk '{print $3}'):2377
        docker swarm join --secret ${DOCKER_SWARM_SECRET} ${LEADER_IP}:2377
    else
        #docker swarm join --manager --secret ${DOCKER_SWARM_SECRET} $(docker -H tcp://$(/giddyup leader get):2375 node ls|grep Yes|awk '{print $3}'):2377
        docker swarm join --manager --secret ${DOCKER_SWARM_SECRET} ${LEADER_IP}:2377
    fi
}

/giddyup leader check
if [ "$?" -eq "0" ]; then
    docker swarm init --auto-accept worker --auto-accept manager --secret ${DOCKER_SWARM_SECRET} 
else
    join
fi

exec socat -d -d TCP-L:2375,fork UNIX:/var/run/docker.sock
