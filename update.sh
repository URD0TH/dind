
#!/bin/bash
# _update.sh
# Mejoras: manejo de errores y carga robusta de variables de entorno
set -euo pipefail
trap 'echo "Error en la línea $LINENO"; exit 1' ERR

# Detectar bash y relanzar si está disponible
if [ -z "${BASH_VERSION:-}" ] && command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
fi

# Cargar variables de entorno de forma robusta o solicitarlas si no existen
if [ -f ".env" ]; then
    set -a
    . .env
    set +a
else
    echo "Archivo .env no encontrado. Se solicitarán los datos para crearlo."
    read -rp "DOCKER_USER: " DOCKER_USER
    read -srp "DOCKER_PASSWORD: " DOCKER_PASSWORD; echo
    read -rp "DOCKER_REGISTRY: " DOCKER_REGISTRY
    echo -e "DOCKER_USER=$DOCKER_USER\nDOCKER_PASSWORD=$DOCKER_PASSWORD\nDOCKER_REGISTRY=$DOCKER_REGISTRY" > .env
    set -a
    . .env
    set +a
fi

# Instalar dependencias (ya lo tienes)
for pkg in git curl cronie; do
    if ! command -v $pkg &> /dev/null; then
        echo "$pkg no está instalado. Instalando..."
        apk update && apk add --no-cache $pkg
    fi
done

# Asegurar que el demonio crond esté corriendo (no uses rc-service en Docker)
if ! pgrep crond >/dev/null 2>&1; then
    echo "Iniciando crond en background..."
    crond
fi

# Asegurar que /root/.cache existe (para evitar error de crontab)
if [ ! -d /root/.cache ]; then
    mkdir -p /root/.cache
fi
# Marcar todos los repos como seguros para git
for repo in /repos/*; do
    if [ -d "$repo/.git" ]; then
        git config --global --add safe.directory "$repo"
    fi
done

# Función para comprobar conexión al registro
function docker_login() {
    if ! docker info 2>&1 | grep -q "$DOCKER_REGISTRY"; then
        echo "Conectando a $DOCKER_REGISTRY..."
        echo "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USER" --password-stdin
    fi
}


# Función para construir y subir imagen Docker (soporta modo CI)
function build_and_push_image() {
    local dir="$1"
    local force_build="${2:-}"
    [ -d "$dir/.git" ] || return
    echo "Cambiando usuario directorio: $dir"
    chown -R 1000:1000 "$dir"
    cd "$dir"
    echo "Revisando $dir"
    git fetch
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u})
    if [ "$LOCAL" = "$REMOTE" ] && [ "$force_build" != "force" ]; then
        echo "No hay cambios en $dir"
        cd ..
        return
    else
        if [ "$LOCAL" != "$REMOTE" ]; then
            echo "Actualizaciones detectadas en $dir, actualizando..."
            git pull
        else
            echo "Forzando build de $dir aunque no haya cambios."
        fi
        cd ..
        chown -R 1000:1000 "$dir"
        if [ ! -f "$dir/Dockerfile" ]; then
            echo "No se encontró Dockerfile en $dir, saltando..."
            return
        fi
        cd "$dir"
        IMAGE_NAME="${DOCKER_REGISTRY}/$(basename $PWD)"
        TAG_LATEST="latest"
        TAG_DATE=$(date +%d%m%Y%H%M%S)
        docker build -t "$IMAGE_NAME:$TAG_LATEST" -t "$IMAGE_NAME:$TAG_DATE" .
        docker_login
        docker push "$IMAGE_NAME:$TAG_LATEST"
        docker push "$IMAGE_NAME:$TAG_DATE"
        docker rmi "$IMAGE_NAME:$TAG_LATEST" "$IMAGE_NAME:$TAG_DATE"
        docker system prune -f
    fi
    cd ..
}


# Soporte para modo CI: ./update.sh --ci [carpeta] [-f|--force]
if [[ "${1:-}" == "--ci" ]]; then
    CI_DIR="${2:-}"
    FORCE_ARG="${3:-}"
    if [ -z "$CI_DIR" ]; then
        echo "Debes indicar la carpeta del repo para CI." | tee -a update.log
        exit 2
    fi
    if [[ "$FORCE_ARG" == "-f" || "$FORCE_ARG" == "--force" ]]; then
        build_and_push_image "$CI_DIR" force | tee -a update.log
    else
        build_and_push_image "$CI_DIR" | tee -a update.log
    fi
    exit $?
fi

# Soporte para login manual: ./update.sh --login
if [[ "${1:-}" == "--login" ]]; then
    docker_login | tee -a update.log
    exit $?
fi

# Recorrer subcarpetas normalmente
for dir in */ ; do
    build_and_push_image "$dir" | tee -a update.log
done

# Agregar al cron si no existe
CRON_JOB="0 6 * * * cd $(pwd) && sh ./update.sh >> update.log 2>&1"
CRON_EXISTS=$(crontab -l 2>/dev/null | grep -F "$CRON_JOB" || true)
if [ -z "$CRON_EXISTS" ]; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "Tarea programada en cron para las 6:00 AM America/Santiago." | tee -a update.log
fi

# Reiniciar cron para aplicar cambios
if command -v service >/dev/null 2>&1; then
    service crond restart
else
    echo "No se pudo reiniciar el servicio crond."  | tee -a update.log
fi