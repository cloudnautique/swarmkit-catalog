# Features

* Automatically scale up/down a Swarm
* Configurable number of managers tunable to desired [failure tolerance](https://docs.docker.com/engine/swarm/admin_guide/#/add-manager-nodes-for-fault-tolerance)
* Reconciliation logic promotes/demotes managers/workers to maintain resilience

# Notes

The SwarmKit stack and the underlying swarm are decoupled. Therefore, deleting the stack will leave the Swarm untouched, but failure recovery will become a manual process.