#!/bin/bash

set -x

export DOCKER_SWARM_SECRET=$(curl -s http://rancher-metadata.rancher.internal/2015-12-19/self/service/uuid)
export SVC_INDEX=$(curl -s http://rancher-metadata.rancher.internal/2015-12-19/self/container/service_index)
/giddyup service wait scale

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

    if [ "${SVC_INDEX}" -gt "2" ]; then
        docker swarm join --secret ${DOCKER_SWARM_SECRET} $(docker -H tcp://$(/giddyup leader get):2375 node ls|grep Yes|awk '{print $3}'):2377
    else
        docker swarm join --manager --secret ${DOCKER_SWARM_SECRET} $(docker -H tcp://$(/giddyup leader get):2375 node ls|grep Yes|awk '{print $3}'):2377
    fi
}

hangout()
{
    while true; do
        sleep 3600
    done
}

/giddyup leader check
if [ "$?" -eq "0" ]; then
    docker swarm init --auto-accept worker --auto-accept manager --secret ${DOCKER_SWARM_SECRET} 
    socat -d -d TCP-L:2375,fork UNIX:/var/run/docker.sock
else
    join
    hangout
fi

