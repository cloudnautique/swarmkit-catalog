package main

import (
	"os"
	"time"

	log "github.com/Sirupsen/logrus"
	rancher "github.com/rancher/go-rancher/v2"
	"github.com/urfave/cli"
)

const (
	rancherTimeout = 5 * time.Second
)

func main() {
	app := cli.NewApp()
	app.Name = "swarmkit"
	app.Version = "1.0"
	app.Usage = "swarm on rancher"
	app.Commands = []cli.Command{
		{
			Name:    "orchestrate",
			Aliases: []string{"o"},
			Usage:   "run the orchestrator",
			Action:  orchestrate,
			Flags: []cli.Flag{
				cli.DurationFlag{
					Name:   "reconcile-period",
					Usage:  "duration of time between reconciliations",
					EnvVar: "RECONCILE_PERIOD",
					Value:  15 * time.Second,
				},
				cli.IntFlag{
					Name:   "manager-count",
					Usage:  "maximum number of managers to elect",
					EnvVar: "MANAGER_COUNT",
					Value:  5,
				},
			},
		},
		{
			Name:    "proxy",
			Aliases: []string{"p"},
			Usage:   "run the api proxy",
			Action:  proxy,
			Flags: []cli.Flag{
				cli.StringFlag{
					Name:   "host",
					Usage:  "host id, uuid, name or hostname",
					EnvVar: "PROXY_HOST",
				},
				cli.StringFlag{
					Name:   "listen",
					Usage:  "endpoint to listen on)",
					EnvVar: "PROXY_BIND",
					Value:  "tcp://0.0.0.0:32376",
				},
			},
		},
	}
	app.Run(os.Args)
}

func orchestrate(c *cli.Context) error {
	managerCount := c.Int("manager-count")
	switch {
	case managerCount <= 0:
		managerCount = 3
	case managerCount == 1:
		log.Warnf("manager-count (%d) is a single point of failure", managerCount)
	case managerCount > 9:
		managerCount = 9
	case managerCount%2 == 0:
		managerCount += 1
	}
	if managerCount != c.Int("manager-count") {
		log.Warnf("invalid manager-count (%d) was overridden (%d)", c.Int("manager-count"), managerCount)
	}

	reconcilePeriod := c.Duration("reconcile-period")
	switch {
	case reconcilePeriod < 1*time.Second:
		reconcilePeriod = 1 * time.Second
	case reconcilePeriod > 5*time.Minute:
		reconcilePeriod = 5 * time.Minute
	}
	if reconcilePeriod != c.Duration("reconcile-period") {
		log.Warnf("invalid reconcile-period (%v) was overridden (%v)", c.Duration("reconcile-period"), reconcilePeriod)
	}

	client := newRancherClient()
	t := time.NewTicker(reconcilePeriod)

	for _ = range t.C {
		if err := newReconciliation(client, managerCount).run(); err != nil {
			log.Error(err)
		}
	}

	return nil
}

func getenv(key string) string {
	value := os.Getenv(key)
	if value == "" {
		log.Warnf("missing %s environment variable", key)
	}
	return value
}

func newRancherClient() *rancher.RancherClient {
	c, err := rancher.NewRancherClient(&rancher.ClientOpts{
		Url:       getenv("CATTLE_URL"),
		AccessKey: getenv("CATTLE_ACCESS_KEY"),
		SecretKey: getenv("CATTLE_SECRET_KEY"),
		Timeout:   rancherTimeout,
	})
	if err != nil {
		log.Fatal(err)
	}
	return c
}
