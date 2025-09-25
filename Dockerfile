# Dockerfile para imagen base basada en docker:latest con git, curl y cronie
FROM docker:latest

RUN apk update && \
    apk add --no-cache git curl cronie github-cli

RUN mkdir /repos && mkdir -p /root/.cache && mkdir -p /etc/docker/

RUN echo '{ "insecure-registries": ["172.22.1.5:5000"] }' > /etc/docker/daemon.json

COPY ./update.sh /repos/update.sh

# Copia el archivo .env al directorio /repos
COPY .env.example /repos/.env

# Configura la zona horaria a America/Santiago
ENV TZ=America/Santiago
ENV PGID=1000
ENV PUID=1000
ENV DOCKER_REGISTRY=regui.lc.bnds.click


RUN chmod +x /repos/update.sh 

VOLUME /var/lib/docker
EXPOSE 2375 2376

VOLUME /repos
WORKDIR /repos


ENTRYPOINT ["dockerd-entrypoint.sh"]
CMD []
