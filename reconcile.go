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
	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/api/types/swarm"
	"github.com/docker/docker/client"
	rancher "github.com/rancher/go-rancher/v2"
)

type Reconcile struct {
	sync.Mutex
	client       *rancher.RancherClient
	managerCount int

	registeredHosts []rancher.Host
	nodes           []swarm.Node
	nodeState       map[swarm.LocalNodeState][]rancher.Host
	managerHosts    []rancher.Host
	workerHosts     []rancher.Host
	managerAddrs    []string

	hostClient  map[string]*client.Client
	hostInfo    map[string]types.Info
	decision    string
	joinTokens  swarm.JoinTokens
	removeNodes []swarm.Node
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
	defer r.cleanup()

	if err := r.observe(); err != nil {
		return err
	}

	if err := r.analyze(); err != nil {
		return err
	}

	if err := r.act(); err != nil {
		return err
	}

	return nil
}

func (r *Reconcile) observe() error {
	if err := r.findHosts(); err != nil {
		return err
	}

	if err := r.getDaemonInfo(); err != nil {
		return err
	}

	if err := r.listNodes(); err != nil {
		return err
	}

	return nil
}

func (r *Reconcile) analyze() error {
	hosts := len(r.registeredHosts)
	nodes := len(r.nodes)
	inactive := len(r.nodeState[swarm.LocalNodeStateInactive])
	pending := len(r.nodeState[swarm.LocalNodeStatePending])
	active := len(r.nodeState[swarm.LocalNodeStateActive])
	error := len(r.nodeState[swarm.LocalNodeStateError])
	locked := len(r.nodeState[swarm.LocalNodeStateLocked])

	managers := len(r.managerHosts)
	workers := len(r.workerHosts)

	switch {
	case pending > 0 || error > 0 || locked > 0:
		// TODO: In general, what should we do when certain daemons aren't reachable,
		// communicable, or in some other bad state?
		return errors.New("Unimplemented")

	case nodes > hosts:
		for _, n := range r.nodes {
			inHosts := false
			for _, h := range r.registeredHosts {
				if n.Status.Addr == h.AgentIpAddress {
					inHosts = true
					break
				}
			}
			if !inHosts {
				r.removeNodes = append(r.removeNodes, n)
			}
		}
		r.decision = "remove-nodes"

	case inactive == hosts:
		r.decision = "new"

	case active == hosts:
		switch {
		case managers < r.managerCount && (managers%2 == 0 && workers >= 1 || workers >= 2):
			r.decision = "promote-worker"
			r.getJoinTokens()
		case managers == 2 && (managers > r.managerCount || workers == 0):
			log.Info("Can't demote node: this would result in a loss of quorum.")
		case managers > r.managerCount || managers%2 == 0 && workers == 0:
			r.decision = "demote-manager"
			r.getJoinTokens()
		}

	default:
		switch {
		case managers < r.managerCount && (managers%2 == 0 || inactive >= 2):
			r.decision = "add-manager"
		default:
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

		if _, err := r.hostClient[h.Id].SwarmInit(context.Background(), req); err != nil {
			return err
		}
		r.addLabel(h)
		log.Info("New cluster manager")
		r.managerHosts = append(r.managerHosts, h)
		fallthrough

	case "create-network":
		opts := types.NetworkCreate{
			CheckDuplicate: true,
			Driver:         "overlay",
			EnableIPv6:     false,
			IPAM: &network.IPAM{
				Driver: "default",
			},
			Internal:   false,
			Attachable: true,
			Ingress:    false,
		}

		name := "rancher"
		for _, h := range r.managerHosts {
			if resp, err := r.hostClient[h.Id].NetworkCreate(context.Background(), name, opts); err != nil {
				log.Warn(err)
			} else {
				f := log.Fields{
					"id":   resp.ID,
					"name": name,
				}
				if resp.Warning != "" {
					f["warning"] = resp.Warning
				}
				log.WithFields(f).Info("Created network")
				break
			}
		}

	case "add-manager":
		// TODO move the selection logic to analyze()
		i := r.nodeState[swarm.LocalNodeStateInactive]
		h := i[rand.Int31n(int32(len(i)))]
		r.joinHost(h, r.joinTokens.Manager)
		r.addLabel(h)
		log.WithFields(log.Fields{
			"decision": r.decision,
		}).Info("Added manager")

	case "add-workers":
		var wg sync.WaitGroup
		for _, h := range r.nodeState[swarm.LocalNodeStateInactive] {
			wg.Add(1)

			go func(h rancher.Host) {
				defer wg.Done()
				if err := r.joinHost(h, r.joinTokens.Worker); err != nil {
					log.WithFields(log.Fields{
						"decision": r.decision,
						"error":    err.Error(),
					}).Warn("Failed to add worker")
				}
				log.WithFields(log.Fields{
					"decision": r.decision,
				}).Info("Added worker")
			}(h)
		}
		wg.Wait()

	case "promote-worker":
		h := r.workerHosts[rand.Int31n(int32(len(r.workerHosts)))]
		if err := r.promoteHost(h); err != nil {
			log.WithField("error", err.Error()).Warn("Failed to promote worker")
			return err
		}
		r.addLabel(h)
		log.WithFields(log.Fields{
			"decision": r.decision,
			"id":       h.Id,
		}).Info("Promoted node")

	case "demote-manager":
		h := r.managerHosts[rand.Int31n(int32(len(r.managerHosts)))]
		if err := r.demoteHost(h); err != nil {
			log.WithField("error", err.Error()).Warn("Failed to demote manager")
			return err
		}
		r.deleteLabel(h)
		log.WithFields(log.Fields{
			"decision": r.decision,
			"id":       h.Id,
		}).Info("Demoted node")

	case "remove-nodes":
		// Demote managers
		for _, n := range r.removeNodes {
			if n.Spec.Role == swarm.NodeRoleManager {
				r.demoteNode(n.ID)
				log.WithFields(log.Fields{
					"id":       n.ID,
					"decision": r.decision,
				}).Info("Demoted node")
			}
		}
		// Remove nodes
		for _, n := range r.removeNodes {
			r.removeNode(n.ID, true)
			log.WithFields(log.Fields{
				"id":       n.ID,
				"decision": r.decision,
			}).Info("Removed node")
		}
	}

	return nil
}

func (r *Reconcile) addLabel(h rancher.Host) {
	h.Labels["manager"] = ""
	r.updateHost(h)
}

func (r *Reconcile) deleteLabel(h rancher.Host) {
	delete(h.Labels, "manager")
	r.updateHost(h)
}

func (r *Reconcile) updateHost(h rancher.Host) {
	if _, err := r.client.Host.Update(&h, h); err != nil {
		log.Warn(err)
	}
}

func (r *Reconcile) cleanup() {
	// close all daemon transports
	for _, c := range r.hostClient {
		c.Close()
	}
}

func (r *Reconcile) joinHost(h rancher.Host, t string) error {
	req := swarm.JoinRequest{
		AdvertiseAddr: h.AgentIpAddress,
		ListenAddr:    "0.0.0.0:2377",
		JoinToken:     t,
		RemoteAddrs:   r.managerAddrs,
	}
	return r.hostClient[h.Id].SwarmJoin(context.Background(), req)
}

func (r *Reconcile) promoteHost(h rancher.Host) error {
	return r.updateHostRole(h, swarm.NodeRoleManager)
}

func (r *Reconcile) demoteHost(h rancher.Host) error {
	return r.updateHostRole(h, swarm.NodeRoleWorker)
}

func (r *Reconcile) demoteNode(id string) error {
	return r.updateNodeRole(id, swarm.NodeRoleWorker)
}

func (r *Reconcile) removeNode(id string, force bool) error {
	var err error
	opts := types.NodeRemoveOptions{
		Force: force,
	}
	for _, m := range r.managerHosts {
		if err = r.hostClient[m.Id].NodeRemove(context.Background(), id, opts); err == nil {
			break
		} else {
			log.Warn(err)
		}
	}
	return err
}

func (r *Reconcile) updateHostRole(h rancher.Host, role swarm.NodeRole) error {
	return r.updateNodeRole(r.hostInfo[h.Id].Swarm.NodeID, role)
}

func (r *Reconcile) updateNodeRole(id string, role swarm.NodeRole) error {
	var wn swarm.Node
	var err error
	for _, m := range r.managerHosts {
		// Managers shouldn't self-demote
		if id == m.Id {
			continue
		}

		if wn, _, err = r.hostClient[m.Id].NodeInspectWithRaw(context.Background(), id); err == nil {
			wn.Spec.Role = role
			err = r.hostClient[m.Id].NodeUpdate(context.Background(), id, wn.Version, wn.Spec)
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

func (r *Reconcile) getDaemonInfo() error {
	clusterID := ""
	var wg sync.WaitGroup
	for _, h := range r.registeredHosts {
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

			r.Lock()
			defer r.Unlock()

			// store docker client and info
			r.hostClient[h.Id] = cli
			r.hostInfo[h.Id] = info

			// build a map of hosts keyed by node state
			r.nodeState[info.Swarm.LocalNodeState] = append(r.nodeState[info.Swarm.LocalNodeState], h)

			// record active managers/workers
			if info.Swarm.LocalNodeState == swarm.LocalNodeStateActive {
				if info.Swarm.ControlAvailable {
					r.managerHosts = append(r.managerHosts, h)
				} else {
					r.workerHosts = append(r.workerHosts, h)
				}
			}

			// try to detect cluster ID
			if info.Swarm.Cluster != nil && info.Swarm.Cluster.ID != "" {
				if clusterID == "" {
					clusterID = info.Swarm.Cluster.ID

					// Hard stop if multiple cluster IDs are identified
				} else if clusterID != info.Swarm.Cluster.ID {
					log.Fatal(fmt.Sprintf("Multiple cluster IDs detected (%s, %s). Split-brain scenario must be manually resolved.", clusterID, info.Swarm.Cluster.ID))
				}
			}
		}(h)
	}
	wg.Wait()

	return nil
}

func (r *Reconcile) listNodes() error {
	var err error
	for _, m := range r.managerHosts {
		if r.nodes, err = r.hostClient[m.Id].NodeList(context.Background(), types.NodeListOptions{}); err == nil {
			break
		} else {
			log.Warn(errors.New(fmt.Sprintf("failed to list nodes: %v", err)))
		}
	}
	return err
}
