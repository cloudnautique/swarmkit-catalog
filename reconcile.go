package main

import (
	"context"
	"errors"
	"fmt"
	"sync"

	log "github.com/Sirupsen/logrus"
	"github.com/docker/docker/api"
	"github.com/docker/docker/api/types"
	"github.com/docker/docker/client"
	rancher "github.com/rancher/go-rancher/v2"
)

type Reconcile struct {
	sync.Mutex
	client          *rancher.RancherClient
	registeredHosts []rancher.Host
	reachableHosts  []rancher.Host
	hostInfo        map[string]types.Info
}

func NewReconciliation(client *rancher.RancherClient) *Reconcile {
	return &Reconcile{
		client:   client,
		hostInfo: make(map[string]types.Info),
	}
}

func (r *Reconcile) run() error {
	if err := r.observe(); err != nil {
		return err
	}

	if err := r.analyze(); err != nil {
		return err
	}

	r.Log()

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
	// TODO
	return nil
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

			if err := ProbeTCP(address); err == nil {
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
