package main

import (
	"errors"
	"fmt"
	"sync"
	"time"

	log "github.com/Sirupsen/logrus"
	rancher "github.com/rancher/go-rancher/v2"
	"github.com/urfave/cli"
)

type Reconcile struct {
	sync.Mutex
	client          *rancher.RancherClient
	registeredHosts []rancher.Host
	reachableHosts  []rancher.Host
}

func orchestrate(c *cli.Context) error {
	c := newRancherClient()
	t := time.NewTicker(c.Duration("reconcile-period"))
	for _ = range t.C {
		r := &Reconcile{
			client: c,
		}
		if err := r.Run(); err != nil {
			return err
		}
	}
	return nil
}

func (r *Reconcile) Log() {
	log.Info("Hostname\t\tState\tHost ID\tAgent IP")
	log.Info("--------\t\t-----\t--------\t--------")
	for _, h := range r.registeredHosts {
		log.Infof("%s\t%s\t%s\t%s", h.Hostname, h.State, h.Id, h.AgentIpAddress)
	}
}

func (r *Reconcile) FindHosts() error {
	h, err := r.client.Host.List(nil)
	if err != nil {
		return err
	}
	if len(h.Data) == 0 {
		return errors.New("No hosts found!")
	}
	r.registeredHosts = h.Data
}

func (r *Reconcile) ProbeHosts() error {
	var wg sync.WaitGroup
	for _, h := range r.registeredHosts {
		wg.Add(1)

		go func(h rancher.Host) {
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

			wg.Done()
		}(h)
	}
	wg.Wait()

}

func (r *Reconcile) run() error {
	if err := r.FindHosts(); err != nil {
		return err
	}
	if err := r.ProbeHosts(); err != nil {
		return err
	}
	// TODO fetch info
	r.Log()

	return nil
}
