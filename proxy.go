package main

import (
	log "github.com/Sirupsen/logrus"
	"github.com/rancher/rancher-docker-api-proxy"
	"github.com/urfave/cli"
)

func proxy(c *cli.Context) error {
	log.Info("proxy()")
	client := newRancherClient()
	proxy := dockerapiproxy.NewProxy(client, "myhost", "tcp://0.0.0.0:32376")
	return proxy.ListenAndServe()
}
