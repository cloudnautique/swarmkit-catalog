FROM alpine:3.4

 RUN \
  apk add --update --no-cache ca-certificates wget && \
  wget -q -O /usr/bin/giddyup https://github.com/cloudnautique/giddyup/releases/download/v0.14.0/giddyup && \
  chmod +x /usr/bin/giddyup

ADD swarmd swarmctl /usr/bin/
ADD run.sh /

ENTRYPOINT ["/run.sh"]