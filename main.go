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
	app.Usage = "swarm on rancher"
	app.Commands = []cli.Command{
		{
			Name:    "orchestrate",
			Aliases: []string{"o"},
			Usage:   "run the orchestrator",
			Action:  orchestrate,
		},
		{
			Name:    "proxy",
			Aliases: []string{"p"},
			Usage:   "run the api proxy",
			Action:  proxy,
		},
	}
	app.Run(os.Args)
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
