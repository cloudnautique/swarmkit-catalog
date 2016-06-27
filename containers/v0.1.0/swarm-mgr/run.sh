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
    docker swarm inspect
    if [ "$?" -ne "0" ]; then
        exists="true"
    fi
    echo ${exists}
}

/giddyup leader check
if [ "$?" -eq "0" ]; then
    if [ "$(swarm_exists)" = "true" ]; then
        docker swarm init --auto-accept worker --auto-accept manager --secret ${DOCKER_SWARM_SECRET} 
    fi
else
    join
fi

exec socat -d -d TCP-L:2375,fork UNIX:/var/run/docker.sock
