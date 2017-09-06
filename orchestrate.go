package main

import (
	"fmt"
	"sync"
	"time"

	log "github.com/Sirupsen/logrus"
	rancher "github.com/rancher/go-rancher/v2"
	"github.com/urfave/cli"
)

type SwarmManager struct {
	rancher *rancher.RancherClient
	hosts   []rancher.Host
}

type Reconciliation struct {
	sync.Mutex
	AllHosts       []rancher.Host
	ReachableHosts []rancher.Host
}

func orchestrate(c *cli.Context) error {
	log.Info("orchestrate()")
	m := &SwarmManager{
		rancher: newRancherClient(),
	}
	m.reconcile()
	t := time.NewTicker(c.Duration("reconcile-period"))
	for _ = range t.C {
		m.reconcile()
	}
	return nil
}

func (r *Reconciliation) Log() {
	log.Info("Hostname\t\tState\tHost ID\tAgent IP")
	log.Info("--------\t\t-----\t--------\t--------")
	for _, h := range r.AllHosts {
		log.Infof("%s\t%s\t%s\t%s", h.Hostname, h.State, h.Id, h.AgentIpAddress)
	}
}

func (r *Reconciliation) FindReachable() {
	var wg sync.WaitGroup
	for _, h := range r.AllHosts {
		wg.Add(1)

		go func(h rancher.Host) {
			address := fmt.Sprintf("%s:%d", h.AgentIpAddress, 2375)

			if err := ProbeTCP(address); err == nil {
				r.Lock()
				r.ReachableHosts = append(r.ReachableHosts, h)
				r.Unlock()
			} else {
				log.WithFields(log.Fields{
					"address": address,
					"error":   err.Error(),
					"host":    h.Id,
				}).Warnf("Couldn't open TCP socket")
			}

			wg.Done()
		}(h)
	}
	wg.Wait()
}

func (m *SwarmManager) reconcile() error {
	h, err := m.rancher.Host.List(nil)
	if err != nil {
		log.Fatal(err)
	}

	r := &Reconciliation{
		AllHosts: h.Data,
	}
	r.FindReachable()
	r.Log()

	return nil
}
