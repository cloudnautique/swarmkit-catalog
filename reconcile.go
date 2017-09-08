package main

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"sync"
	"time"

	log "github.com/Sirupsen/logrus"
	"github.com/docker/docker/api"
	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/swarm"
	"github.com/docker/docker/client"
	rancher "github.com/rancher/go-rancher/v2"
)

type Reconcile struct {
	sync.Mutex
	client       *rancher.RancherClient
	managerCount int

	registeredHosts []rancher.Host
	reachableHosts  []rancher.Host
	nodeState       map[swarm.LocalNodeState][]rancher.Host
	managerHosts    []rancher.Host
	workerHosts     []rancher.Host
	managerAddrs    []string

	hostClient map[string]*client.Client
	hostInfo   map[string]types.Info
	decision   string
	joinTokens swarm.JoinTokens
}

func newReconciliation(c *rancher.RancherClient, m int) *Reconcile {
	return &Reconcile{
		client:       c,
		managerCount: m,
		nodeState:    make(map[swarm.LocalNodeState][]rancher.Host),
		hostClient:   make(map[string]*client.Client),
		hostInfo:     make(map[string]types.Info),
	}
}

func (r *Reconcile) run() error {
	if err := r.observe(); err != nil {
		return err
	}

	if err := r.analyze(); err != nil {
		return err
	}

	if err := r.act(); err != nil {
		return err
	}

	// TODO get rid of this
	// r.Log()

	return nil
}

func (r *Reconcile) observe() error {
	if err := r.findHosts(); err != nil {
		return err
	}

	if err := r.probeDaemons(); err != nil {
		return err
	}

	if err := r.getDaemonInfo(); err != nil {
		return err
	}

	return nil
}

func (r *Reconcile) analyze() error {
	// TODO: In general, what should we do when certain daemons aren't reachable or communicable?

	clusterID := ""
	for _, h := range r.reachableHosts {
		if i, ok := r.hostInfo[h.Id]; ok {
			// build a map of hosts keyed by node state
			r.nodeState[i.Swarm.LocalNodeState] = append(r.nodeState[i.Swarm.LocalNodeState], h)

			// record active managers/workers
			if i.Swarm.LocalNodeState == swarm.LocalNodeStateActive {
				if i.Swarm.ControlAvailable {
					r.managerHosts = append(r.managerHosts, h)
				} else {
					r.workerHosts = append(r.workerHosts, h)
				}
			}

			// try to detect cluster ID
			if i.Swarm.Cluster.ID != "" {
				if clusterID == "" {
					clusterID = i.Swarm.Cluster.ID

					// Error out if multiple cluster IDs are identified
				} else if clusterID != i.Swarm.Cluster.ID {
					return errors.New(fmt.Sprintf("Multiple cluster IDs detected (%s, %s). Split-brain scenario must be manually resolved.", clusterID, i.Swarm.Cluster.ID))
				}
			}
		}
	}

	total := len(r.reachableHosts)
	inactive := len(r.nodeState[swarm.LocalNodeStateInactive])
	// pending := len(r.nodeState[swarm.LocalNodeStatePending])
	active := len(r.nodeState[swarm.LocalNodeStateActive])
	// error := len(r.nodeState[swarm.LocalNodeStateError])
	// locked := len(r.nodeState[swarm.LocalNodeStateLocked])

	managers := len(r.managerHosts)
	// workers := len(r.workerHosts)

	// We create a Swarm iff info from all reachable hosts indicates no existing Swarm
	if inactive == total {
		r.decision = "new"
		return nil
	}

	// maybeSwarmExists := false
	// for _, h := range r.reachableHosts {
	// 	if i, ok := r.hostInfo[h.Id]; ok {
	// 		maybeSwarmExists = maybeSwarmExists || (i.Swarm.LocalNodeState != swarm.LocalNodeStateInactive)

	// 		// If we didn't get an API response, a Swarm might already exist
	// 	} else {
	// 		maybeSwarmExists = true
	// 		break
	// 	}
	// }
	// if !maybeSwarmExists {
	// 	r.decision = "new"
	// 	return nil
	// }

	// Fail out if multiple swarm cluster IDs are identified
	// clusterID := ""
	// for _, h := range r.reachableHosts {
	// 	if i, ok := r.hostInfo[h.Id]; ok {
	// 		if i.Swarm.Cluster.ID != "" {
	// 			if clusterID != "" {
	// 				if clusterID != i.Swarm.Cluster.ID {
	// 					return errors.New(fmt.Sprintf("Multiple cluster IDs detected (%s, %s). Split-brain scenario must be manually resolved.", clusterID, i.Swarm.Cluster.ID))
	// 				}
	// 			} else {
	// 				clusterID = i.Swarm.Cluster.ID
	// 			}
	// 		}
	// 	}
	// }

	// We add nodes to a Swarm iff info from all daemons are inactive/active
	if active > 0 && inactive > 0 && active+inactive == total {
		// get join tokens
		for _, h := range r.managerHosts {
			if s, err := r.hostClient[h.Id].SwarmInspect(context.Background()); err == nil {
				r.joinTokens = s.JoinTokens

				for _, m := range r.hostInfo[h.Id].Swarm.RemoteManagers {
					r.managerAddrs = append(r.managerAddrs, m.Addr)
				}
				break
			}
		}
		// add a manager if we haven't reached desired count and have sufficient
		// inactive hosts to achieve the next largest odd number of managers
		if managers < r.managerCount && (managers%2 == 0 || inactive >= 2) {
			r.decision = "add-manager"
		} else {
			r.decision = "add-workers"
		}

		return nil
	}

	// exist without any questionable-state nodes
	// for _, h := range r.reachableHosts {
	// }

	return nil
}

func (r *Reconcile) act() error {
	rand.Seed(time.Now().UnixNano())

	switch r.decision {
	case "new":
		log.Info("Creating new Swarm cluster")

		i := r.nodeState[swarm.LocalNodeStateInactive]
		h := i[rand.Int31n(int32(len(i)))]

		req := swarm.InitRequest{
			AdvertiseAddr: h.AgentIpAddress,
			ListenAddr:    "0.0.0.0:2377",
		}

		if id, err := r.hostClient[h.Id].SwarmInit(context.Background(), req); err != nil {
			return err
		} else {
			log.WithField("node-id", id).Info("Created new cluster")
		}

	case "add-manager":
		log.Info("Adding manager")
		i := r.nodeState[swarm.LocalNodeStateInactive]
		h := i[rand.Int31n(int32(len(i)))]
		return r.addNode(h, r.joinTokens.Manager)

	case "add-workers":
		log.Info("Adding worker")
		i := r.nodeState[swarm.LocalNodeStateInactive]
		h := i[rand.Int31n(int32(len(i)))]
		return r.addNode(h, r.joinTokens.Worker)
	}

	return nil
}

func (r *Reconcile) addNode(h rancher.Host, t string) error {
	req := swarm.JoinRequest{
		AdvertiseAddr: h.AgentIpAddress,
		ListenAddr:    "0.0.0.0:2377",
		JoinToken:     t,
		RemoteAddrs:   r.managerAddrs,
	}
	return r.hostClient[h.Id].SwarmJoin(context.Background(), req)
}

func (r *Reconcile) findHosts() error {
	h, err := r.client.Host.List(nil)
	if err != nil {
		return err
	}
	if len(h.Data) == 0 {
		return errors.New("No hosts found!")
	}
	r.registeredHosts = h.Data
	return nil
}

func (r *Reconcile) probeDaemons() error {
	var wg sync.WaitGroup
	for _, h := range r.registeredHosts {
		wg.Add(1)

		go func(h rancher.Host) {
			defer wg.Done()
			address := fmt.Sprintf("%s:%d", h.AgentIpAddress, 2375)

			if err := probeTCP(address); err == nil {
				r.Lock()
				r.reachableHosts = append(r.reachableHosts, h)
				r.Unlock()
			} else {
				log.WithFields(log.Fields{
					"address":  address,
					"error":    err.Error(),
					"hostname": h.Hostname,
				}).Warnf("Couldn't open TCP socket")
			}
		}(h)
	}
	wg.Wait()

	if len(r.reachableHosts) == 0 {
		return errors.New("No hosts with reachable Docker daemons detected!")
	}
	return nil
}

func (r *Reconcile) getDaemonInfo() error {
	var wg sync.WaitGroup
	for _, h := range r.reachableHosts {
		wg.Add(1)

		go func(h rancher.Host) {
			defer wg.Done()
			address := fmt.Sprintf("tcp://%s:%d", h.AgentIpAddress, 2375)

			cli, err := client.NewClient(address, api.DefaultVersion, nil, nil)
			if err != nil {
				log.Warn(err)
				return
			}
			cli.NegotiateAPIVersion(context.Background())

			info, err := cli.Info(context.Background())
			if err != nil {
				log.Warn(err)
				return
			}
			r.hostClient[h.Id] = cli
			r.hostInfo[h.Id] = info
		}(h)
	}
	wg.Wait()

	return nil
}

func (r *Reconcile) Log() {
	log.Info("Hostname\t\tState\tHost ID\tAgent IP")
	log.Info("--------\t\t-----\t--------\t--------")
	for _, h := range r.registeredHosts {
		log.Infof("%s\t%s\t%s\t%s", h.Hostname, h.State, h.Id, h.AgentIpAddress)
	}
}
