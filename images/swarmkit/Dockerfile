FROM alpine:3.4

RUN \
  apk add --update --no-cache curl jq bash socat && \
  curl -sfL -o /usr/bin/giddyup https://github.com/cloudnautique/giddyup/releases/download/v0.14.0/giddyup && \
  chmod +x /usr/bin/giddyup

RUN \
  cd /tmp && \
  curl -sfL https://get.docker.com/builds/Linux/x86_64/docker-1.12.0.tgz | tar -xzf - && \
  cp docker/docker /usr/bin/docker-1.12.0 && \
  rm -rf docker/ && \
  curl -sfL https://get.docker.com/builds/Linux/x86_64/docker-1.12.1.tgz | tar -xzf - && \
  cp docker/docker /usr/bin/docker-1.12.1 && \
  rm -rf docker/ && \
  ln -fs /usr/bin/docker-1.12.1 /usr/bin/docker

WORKDIR /opt/rancher
ENV PATH $PATH:/opt/rancher
ADD run.sh run_1.12.0.sh run_1.12.1.sh disaster /opt/rancher

CMD ["/run.sh"]