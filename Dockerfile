# Dockerfile para imagen base basada en docker:latest con git, curl y cronie
FROM docker:latest

RUN apk update && \
    apk add --no-cache git curl cronie

RUN mkdir /repos && mkdir -p /root/.cache

COPY ./update.sh /repos/update.sh

# Copia el archivo .env al directorio /repos
COPY .env.example /repos/.env

# Configura la zona horaria a America/Santiago
ENV TZ=America/Santiago
ENV PGID=1000
ENV PUID=1000

RUN chmod +x /repos/update.sh 

RUN sh /repos/update.sh >> /var/log/update_repos.log 2>&1

VOLUME ["/repos"]

CMD ["sh"]
