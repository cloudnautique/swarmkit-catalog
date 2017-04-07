FROM alpine:3.5
ADD swarmkit /usr/bin/
ENTRYPOINT ["/usr/bin/swarmkit"]