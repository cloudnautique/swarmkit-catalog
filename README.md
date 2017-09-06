swarmkit-mon
============

SwarmKit Monitor is a cross-platform program that actively manages a Docker Swarm within a Rancher environment. The [CoreOS Operator model](https://coreos.com/operators/) is followed.

## Features

* Configurable host resiliency
* Health check managers/workers and promote/demote as necessary to maintain resiliency
* Import existing Windows/Linux swarm clusters

## Troubleshooting

### Operator reports "Couldn't open TCP Socket" for one or more hosts

This indicates that the Docker API isn't accessible to the Operator on one or more hosts. Follow the check list:

#### Host IP address correct in the UI?

The IP address displayed in the UI for each host needs to be accessible from all other hosts and Rancher server itself. Rancher agent attempts to autodetect the IP address, but it might not work in atypical network topologies or where NAT is used. If the IP addresses are incorrect, [re-register the hosts with the correct IP](http://rancher.com/docs/rancher/v1.6/en/faqs/troubleshooting/#are-the-ips-of-the-hosts-correct-in-the-ui).

#### Docker daemon configured to listen on port 2375?

The Docker daemon must expose its API on port 2375 of the interface corresponding with the configured agent IP address.

To check this, run `netstat -abn` on the Windows host and look at what addresses `dockerd.exe` is listening on. An example of a valid (but possible insecure) configuration:

```
  TCP    0.0.0.0:2375           0.0.0.0:0              LISTENING
 [dockerd.exe]
```

If there is no such entry, adjust `C:\ProgramData\docker\config\daemon.json` to include `tcp://<agent_ip>:2375` (or possible `tcp://0.0.0.0:2375`) under `hosts` section.

Note: If your host is directly connected to the Internet (not behind a NAT router, proxy or similar), you *must not* expose the Docker API on all interfaces (`0.0.0.0`), but instead explicitly specify `<agent_ip>:2375`, where `<agent_ip>` belongs to a private network interface.

#### Host firewall configured to allow inbound TCP traffic on port 2375?

By default, `Windows Server 2016` and similar will not allow inbound traffic except on a few whitelisted ports. If you can access the Docker API via port 2375 from your host, but not others, your firewall is probably not configured to allow the connection.

To allow inbound connections to the Docker Daemon, run the following command on afflicted hosts:

`netsh advfirewall firewall add rule name="Docker Daemon" dir=in action=allow protocol=TCP localport=2375`