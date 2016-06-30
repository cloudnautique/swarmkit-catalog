#!/bin/bash

set -x

export META_URL="http://rancher-metadata.rancher.internal/2015-12-19"
export DOCKER_SWARM_SECRET=$(curl -s ${META_URL}/self/service/uuid)
/giddyup service wait scale

container_ip()
{
    IP=$(curl -s -H 'Accept: application/json' ${META_URL}/self/service/containers/${1}|jq -r .primary_ip)
    echo ${IP}
}

is_swarm_member()
{
    active=false
    if docker -H tcp://${1}:2375 info 2>&1|grep Swarm\:\ active > /dev/null ; then
        active="true"
    fi

    echo ${active}
}

get_manager_agent_ip()
{
    for container in $(/giddyup service containers -n); do
        ip=$(container_ip $container)
        
        if [ "$(is_swarm_manager ${ip})" = "true"  ]; then
            UUID=$(curl -s -H 'Accept: application/json' ${META_URL}/self/service/containers/${container}|jq -r '.host_uuid')
    		IP=$(curl -s -H 'Accept: application/json' ${META_URL}/hosts |jq -r ".[] | select(.uuid==\"${UUID}\") | .agent_ip")
    		echo ${IP}
            return 
        fi
    done
}

get_manager_ip()
{
    for container in $(/giddyup service containers -n); do
        svc_index="$(curl -s -H 'Accept: application/json' ${META_URL}/self/service/containers/${container} | jq -r '.service_index')"
        ip=$(container_ip $container)

        if [ "$(is_swarm_manager ${ip})" = "true"  ]; then
            echo "${ip}"
            return 
        fi
    done
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
    LEADER_IP=$(get_manager_agent_ip)
    if [ "$(is_swarm_member ${1})" = "true" ] && [ "$(is_swarm_manager ${1})" = "true" ]; then 
            demote_node $(get_swarm_node_id ${1})
    fi

    if [ "$(is_swarm_member ${1})" = "false" ]; then
       docker -H tcp://${1}:2375 swarm join --secret ${DOCKER_SWARM_SECRET} ${LEADER_IP}:2377
    fi
}

add_manager()
{
    LEADER_IP=$(get_manager_agent_ip)
    if [ "$(is_swarm_member ${1})" = "true" ] && [ "$(is_swarm_manager ${1})" = "false" ]; then 
            promote_node $(get_swarm_node_id ${1})
    fi

    if [ "$(is_swarm_member ${1})" = "false" ];then
        docker -H tcp://${1}:2375 swarm join --manager --secret ${DOCKER_SWARM_SECRET} ${LEADER_IP}:2377
    fi
}

while true; do
    if /giddyup leader check ; then
        if [ "$(is_swarm_member $(/giddyup leader get))" = "false" ]; then
            docker swarm init --auto-accept worker --auto-accept manager --secret ${DOCKER_SWARM_SECRET} 
        fi
   
        # reconcile_state
        for container in $(/giddyup service containers -n); do
            svc_index="$(curl -s -H 'Accept: application/json' ${META_URL}/self/service/containers/${container} | jq -r '.service_index')"
            if [ "${svc_index}" -le "3" ]; then 
                add_manager  $(container_ip $container)
            else
                add_worker $(container_ip $container)
            fi     
        done
    fi
    sleep 60
done
