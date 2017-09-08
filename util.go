package main

import (
	"net"
	"time"
)

const probeTimeout = 5 * time.Second

func probeTCP(address string) error {
	conn, err := net.DialTimeout("tcp", address, probeTimeout)
	if err != nil {
		return err
	}
	conn.Close()
	return nil
}
