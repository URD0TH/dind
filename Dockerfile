# Dockerfile para imagen base basada en docker:latest con git, curl y cronie
FROM docker:latest

RUN apk update && \
    apk add --no-cache git curl cronie

RUN mkdir /repos && mkdir -p /root/.cache && mkdir -p /etc/docker/

RUN touch /etc/docker/daemon.json

RUN sed -i 's/{}/{ "insecure-registries": ["172.22.1.5:5000"] }/' /etc/docker/daemon.json


COPY ./update.sh /repos/update.sh

# Copia el archivo .env al directorio /repos
COPY .env.example /repos/.env

# Configura la zona horaria a America/Santiago
ENV TZ=America/Santiago
ENV PGID=1000
ENV PUID=1000

RUN chmod +x /repos/update.sh 

VOLUME ["/repos"]

CMD ["sh", "/repos/update.sh"]
