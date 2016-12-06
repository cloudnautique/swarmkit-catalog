FROM alpine:3.4

RUN \
  apk add --update --no-cache curl jq bash bash-completion && \
  curl -sfL -o /usr/bin/giddyup https://github.com/cloudnautique/giddyup/releases/download/v0.14.0/giddyup && \
  chmod +x /usr/bin/giddyup

ENV DOCKER_VERSION 1.13.0-rc3
RUN \
  cd /tmp && \
  curl -sfL https://test.docker.com/builds/Linux/x86_64/docker-$DOCKER_VERSION.tgz | tar -xzf - && \
  cp docker/docker /usr/bin/docker && \
  rm -rf docker/ && \
  curl -sfL https://raw.githubusercontent.com/docker/docker/v$DOCKER_VERSION/contrib/completion/bash/docker -o /usr/share/bash-completion/completions/docker

ENV HOME /opt/rancher
WORKDIR $HOME
ENV PATH $PATH:/opt/rancher
ADD run.sh health.sh .bashrc /opt/rancher/

CMD ["/opt/rancher/run.sh"]