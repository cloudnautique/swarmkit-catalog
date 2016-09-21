#!/bin/bash
exec socat -d -d TCP-L:2375,fork UNIX:/var/run/docker.sock
