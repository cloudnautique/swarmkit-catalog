## Features

* Automatically scale up/down a Swarm
* Configurable number of managers tunable to desired [failure tolerance](https://docs.docker.com/engine/swarm/admin_guide/#/add-manager-nodes-for-fault-tolerance)
* Reconciliation logic promotes/demotes managers/workers to maintain resilience

## Prerequisites

* Port `2377` and `2378` must be open for Swarm and health checks to function

SwarmKit's overlay network configuration must determine which interface will be used to communicate with other hosts. By default, Rancher routes traffic over public IP addresses. Swarm can't cope with that automatically, so you must do one of the following:

* Register hosts with CATTLE_AGENT_IP environment variable set to a system address
* Specify the host interface for Swarm to listen on (all hosts must have the same interface name)
