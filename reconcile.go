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
	pending := len(r.nodeState[swarm.LocalNodeStatePending])
	active := len(r.nodeState[swarm.LocalNodeStateActive])
	error := len(r.nodeState[swarm.LocalNodeStateError])
	locked := len(r.nodeState[swarm.LocalNodeStateLocked])

	managers := len(r.managerHosts)
	workers := len(r.workerHosts)

	// TODO: In general, what should we do when certain daemons aren't reachable,
	// communicable, or in some other bad state?
	if pending > 0 || error > 0 || locked > 0 {

	}

	switch {
	case pending > 0 || error > 0 || locked > 0:
		return errors.New("Unimplemented")

	case inactive == total:
		r.decision = "new"

	case active == total:
		if managers < r.managerCount && (managers%2 == 0 && workers >= 1 || workers >= 2) {
			r.decision = "promote-worker"
			r.getJoinTokens()
		} else if managers > r.managerCount {
			r.decision = "demote-manager"
			r.getJoinTokens()
			if managers == 2 {
				log.Warn("The 2->1 manager transition is unsafe!")
			}
		}

	default:
		if managers < r.managerCount && (managers%2 == 0 || inactive >= 2) {
			r.decision = "add-manager"
		} else {
			r.decision = "add-workers"
		}
		r.getJoinTokens()
	}

	return nil
}

func (r *Reconcile) getJoinTokens() {
	for _, h := range r.managerHosts {
		if s, err := r.hostClient[h.Id].SwarmInspect(context.Background()); err == nil {
			r.joinTokens = s.JoinTokens

			for _, m := range r.hostInfo[h.Id].Swarm.RemoteManagers {
				r.managerAddrs = append(r.managerAddrs, m.Addr)
			}
			break
		}
	}
}

func (r *Reconcile) act() error {
	rand.Seed(time.Now().UnixNano())

	switch r.decision {
	case "new":
		i := r.nodeState[swarm.LocalNodeStateInactive]
		h := i[rand.Int31n(int32(len(i)))]

		req := swarm.InitRequest{
			AdvertiseAddr: h.AgentIpAddress,
			ListenAddr:    "0.0.0.0:2377",
		}

		if id, err := r.hostClient[h.Id].SwarmInit(context.Background(), req); err != nil {
			return err
		} else {
			log.WithField("node-id", id).Info("New cluster manager")
		}

	case "add-manager":
		// TODO move the selection logic to analyze()
		i := r.nodeState[swarm.LocalNodeStateInactive]
		h := i[rand.Int31n(int32(len(i)))]
		r.addNode(h, r.joinTokens.Manager)
		log.Info("Added manager")

	case "add-workers":
		var wg sync.WaitGroup
		for _, h := range r.nodeState[swarm.LocalNodeStateInactive] {
			wg.Add(1)

			go func(h rancher.Host) {
				defer wg.Done()
				if err := r.addNode(h, r.joinTokens.Worker); err != nil {
					log.WithField("error", err.Error()).Warn("Failed to add worker")
				}
				log.Info("Added worker")
			}(h)
		}
		wg.Wait()

	case "promote-worker":
		h := r.workerHosts[rand.Int31n(int32(len(r.workerHosts)))]
		if err := r.promoteNode(h); err != nil {
			log.WithField("error", err.Error()).Warn("Failed to promote worker")
			return err
		}
		log.Info("Promoted worker")

	case "demote-manager":
		h := r.managerHosts[rand.Int31n(int32(len(r.managerHosts)))]
		if err := r.demoteNode(h); err != nil {
			log.WithField("error", err.Error()).Warn("Failed to demote manager")
			return err
		}
		log.Info("Demoted manager")
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

func (r *Reconcile) promoteNode(h rancher.Host) error {
	return r.updateNodeRole(h, swarm.NodeRoleManager)
}

func (r *Reconcile) demoteNode(h rancher.Host) error {
	return r.updateNodeRole(h, swarm.NodeRoleWorker)
}

func (r *Reconcile) updateNodeRole(h rancher.Host, role swarm.NodeRole) error {
	var wn swarm.Node
	var err error
	for _, m := range r.managerHosts {
		// Managers shouldn't self-demote
		if h.Id == m.Id {
			continue
		}

		nodeID := r.hostInfo[h.Id].Swarm.NodeID

		if wn, _, err = r.hostClient[m.Id].NodeInspectWithRaw(context.Background(), nodeID); err == nil {
			wn.Spec.Role = role
			err = r.hostClient[m.Id].NodeUpdate(context.Background(), nodeID, wn.Version, wn.Spec)
			break
		} else {
			log.Warn(err)
		}
	}
	return err
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
