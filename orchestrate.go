package main

import (
	"time"

	log "github.com/Sirupsen/logrus"
	rancher "github.com/rancher/go-rancher/v2"
	"github.com/rancher/rancher-docker-api-proxy"
	"github.com/urfave/cli"
)

type SwarmManager struct {
	rancher    *rancher.RancherClient
	apiClients map[string]*dockerapiproxy.Proxy
	hosts      []rancher.Host
	host       string
	listen     string
}

func orchestrate(c *cli.Context) error {
	log.Info("orchestrate()")
	m := &SwarmManager{
		rancher: newRancherClient(),
		proxy:   make(map[string]*dockerapiproxy.Proxy),
		host:    c.String("host"),
		listen:  c.String("listen"),
	}
	m.reconcile()
	t := time.NewTicker(c.Duration("reconcile-period"))
	for _ = range t.C {
		m.reconcile()
	}
	return nil
}

func (m *SwarmManager) reconcile() error {
	hosts, err := m.rancher.Host.List(nil)
	if err != nil {
		log.Fatal(err)
	}

	log.Info("Hostname\t\tState\tHost ID")
	log.Info("--------\t\t-----\t--------")
	for _, host := range hosts.Data {

		proxy := dockerapiproxy.NewProxy(m.client, m.host, m.listen)
		return proxy.ListenAndServe()
		log.Infof("%s\t%s\t%+v", host.Hostname, host.State, host.Id)
	}
	return nil
}
