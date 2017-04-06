package main

import (
  "time"

  log "github.com/Sirupsen/logrus"
)

const (
  reconcilePeriod = 10 * time.Second
)

func main() {
  log.Info("main()")

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
