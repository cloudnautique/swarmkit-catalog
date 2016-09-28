# Features

* Automatically scale up/down a Swarm
* Configurable number of managers tunable to desired [failure tolerance](https://docs.docker.com/engine/swarm/admin_guide/#/add-manager-nodes-for-fault-tolerance)
* Reconciliation logic promotes/demotes managers/workers to maintain resilience

# Notes

The SwarmKit stack and the underlying swarm are decoupled. The following behavior is advantageous:

1. Users wanting the "native" swarm experience (no automatic recovery in failure situations) can simply delete the stack after all containers become healthy
2. If the automation has a bug, deleting/recreating the stack won't affect availability (but please file a bug report!)
