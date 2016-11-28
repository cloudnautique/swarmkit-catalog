FROM alpine:3.4

RUN \
  apk add --update --no-cache curl jq bash bash-completion && \
  curl -sfL -o /usr/bin/giddyup https://github.com/cloudnautique/giddyup/releases/download/v0.14.0/giddyup && \
  chmod +x /usr/bin/giddyup

RUN \
  cd /tmp && \
  curl -sfL https://get.docker.com/builds/Linux/x86_64/docker-1.12.3.tgz | tar -xzf - && \
  cp docker/docker /usr/bin/docker && \
  rm -rf docker/ && \
  curl -sfL https://raw.githubusercontent.com/docker/docker/v1.12.3/contrib/completion/bash/docker -o /usr/share/bash-completion/completions/docker

ENV HOME /opt/rancher
WORKDIR $HOME
ENV PATH $PATH:/opt/rancher
ADD run.sh health.sh .bashrc /opt/rancher/

CMD ["/opt/rancher/run.sh"]