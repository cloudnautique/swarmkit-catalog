FROM alpine:3.4

ENV SSL_SCRIPT_COMMIT 98660ada3d800f653fc1f105771b5173f9d1a019

RUN \
  apk add --update --no-cache curl jq bash bash-completion && \
  curl -sfL -o /usr/bin/giddyup https://github.com/cloudnautique/giddyup/releases/download/v0.14.0/giddyup && \
  chmod +x /usr/bin/giddyup && \
  curl -sLf https://raw.githubusercontent.com/rancher/rancher/${SSL_SCRIPT_COMMIT}/server/bin/update-rancher-ssl > /usr/bin/update-rancher-ssl && \
  chmod +x /usr/bin/update-rancher-ssl

ENV DOCKER_VERSION 17.03.1-ce
RUN \
  cd /tmp && \
  curl -sfL https://download.docker.com/linux/static/stable/x86_64/docker-$DOCKER_VERSION.tgz | tar -xzf - && \
  cp docker/docker /usr/bin/docker && \
  rm -rf docker/ && \
  curl -sfL https://raw.githubusercontent.com/docker/docker/v$DOCKER_VERSION/contrib/completion/bash/docker -o /usr/share/bash-completion/completions/docker

ENV HOME /opt/rancher
WORKDIR $HOME
ENV PATH $PATH:/opt/rancher
ADD run.sh health.sh .bashrc /opt/rancher/

CMD ["/opt/rancher/run.sh"]
