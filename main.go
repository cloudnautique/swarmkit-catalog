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
	client := newRancherClient()
	t := time.NewTicker(c.Duration("reconcile-period"))

	for _ = range t.C {
		if err := newReconciliation(client, c.Int("manager-count")).run(); err != nil {
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
