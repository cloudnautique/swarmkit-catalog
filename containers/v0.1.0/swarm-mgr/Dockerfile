FROM docker:1.12.0-rc1
RUN apk add --update bash curl drill jq socat && \
    rm -rf /var/cache/apk/*
ADD ./run.sh /run.sh
ADD https://github.com/cloudnautique/giddyup/releases/download/v0.12.0/giddyup /giddyup
RUN chmod +x /giddyup
CMD /run.sh
