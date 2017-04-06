FROM alpine:3.5
ADD code/swarmkit /usr/bin/
ENTRYPOINT ["/usr/bin/swarmkit"]