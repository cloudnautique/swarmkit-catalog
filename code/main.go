package main

import (
	"os"
	"time"

	log "github.com/Sirupsen/logrus"
	client "github.com/rancher/go-rancher/v2"
)

const (
	reconcilePeriod = 15 * time.Second
	rancherTimeout  = 5 * time.Second
)

func getenv(key string) string {
	value := os.Getenv(key)
	if value == "" {
		log.Fatalf("missing %s environment variable", key)
	}
	return value
}

func newClient() *client.RancherClient {
	clientOpts := &client.ClientOpts{
		Url:       getenv("CATTLE_URL"),
		AccessKey: getenv("CATTLE_ACCESS_KEY"),
		SecretKey: getenv("CATTLE_SECRET_KEY"),
		Timeout:   rancherTimeout,
	}

	c, err := client.NewRancherClient(clientOpts)
	if err != nil {
		log.Fatal(err)
	}
	return c
}

func main() {
	log.Info("main()")
	c := newClient()

	if hosts, err := c.Host.List(nil); err == nil {
		log.Info("Hostname\t\tState\tAgent IP")
		log.Info("--------\t\t-----\t--------")
		for _, host := range hosts.Data {
			//f := host.Data["fields"]
			log.Infof("%s\t%s\t%+v", host.Hostname, host.State, host.AgentIpAddress)
			//log.Infof("%+v", host.Data)
		}
	}

	periodically(reconcilePeriod, reconcile)
}

func periodically(p time.Duration, do func()) {
	t := time.NewTicker(p)
	for _ = range t.C {
		do()
	}
}

func reconcile() {
	log.Info("reconcile()")
}
