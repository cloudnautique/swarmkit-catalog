package main

import (
	"time"

	log "github.com/Sirupsen/logrus"
	"github.com/urfave/cli"
)

const (
	reconcilePeriod = 15 * time.Second
)

func orchestrate(c *cli.Context) error {
	log.Info("orchestrate()")
	client := newRancherClient()
	t := time.NewTicker(reconcilePeriod)
	for _ = range t.C {
		hosts, err := client.Host.List(nil)
		if err != nil {
			log.Fatal(err)
		}

		log.Info("Hostname\t\tState\tHost ID")
		log.Info("--------\t\t-----\t--------")
		for _, host := range hosts.Data {
			log.Infof("%s\t%s\t%+v", host.Hostname, host.State, host.Id)
		}
	}
	return nil
}
