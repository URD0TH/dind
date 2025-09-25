#!/bin/bash
# _update.sh
set -euo pipefail
trap 'echo "Error en la línea $LINENO"; exit 1' ERR

# Relanzar en bash si se ejecutó con sh
if [ -z "${BASH_VERSION:-}" ] && command -v bash >/dev/null; then
    exec bash "$0" "$@"
fi

# Verificar opción --git o -g
if [[ "${1:-}" == "--git" || "${1:-}" == "-g" ]]; then
    if ! command -v gh >/dev/null; then
        echo "❌ GitHub CLI (gh) no está instalado."
        exit 1
    fi
    echo "🔐 Verificando autenticación con GitHub CLI..."
    if ! gh auth status &>/dev/null; then
        echo "⚠️ No has iniciado sesión. Ejecuta: gh auth login"
        exit 1
    fi
    echo "✅ Autenticación OK. Configurando Git con gh como helper..."
    git config --global credential.helper '!gh auth git-credential'
    echo "Helper actual: $(git config --global --get credential.helper)"
    exit 0
fi

# Cargar .env o solicitarlo
if [ -f ".env" ]; then
    set -a; . .env; set +a
else
    echo "⚠️ .env no encontrado. Solicitando datos..."
    read -rp "DOCKER_USER: " DOCKER_USER
    read -srp "DOCKER_PASSWORD: " DOCKER_PASSWORD; echo
    read -rp "DOCKER_REGISTRY: " DOCKER_REGISTRY
    echo -e "DOCKER_USER=$DOCKER_USER\nDOCKER_PASSWORD=$DOCKER_PASSWORD\nDOCKER_REGISTRY=$DOCKER_REGISTRY" > .env
    set -a; . .env; set +a
fi

# Asegurar /usr/sbin en PATH (para crond)
export PATH=$PATH:/usr/sbin

# Instalar dependencias (validando binarios reales)
declare -A pkg_map=( [git]=git [curl]=curl [cronie]=crond )
for pkg in "${!pkg_map[@]}"; do
    bin=${pkg_map[$pkg]}
    if ! command -v "$bin" &>/dev/null; then
        echo "⏳ Instalando $pkg..."
        apk update && apk add --no-cache "$pkg"
    else
        echo "✅ $pkg ya instalado."
    fi
done

# Asegurar crond corriendo
pgrep crond &>/dev/null || { echo "▶️ Iniciando crond..."; crond; }

# Asegurar /root/.cache para evitar error en crontab
mkdir -p /root/.cache

# Marcar repos como seguros para git
for repo in /repos/*; do
    [ -d "$repo/.git" ] && git config --global --add safe.directory "$repo"
done
# Docker login
function docker_login() {
    if ! docker info 2>&1 | grep -q "$DOCKER_REGISTRY"; then
        echo "🛂 Conectando a $DOCKER_REGISTRY..."
        echo "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USER" --password-stdin
    fi
}

# Build + push
function build_and_push_image() {
    local dir="$1"
    local force="${2:-}"
    [ -d "$dir/.git" ] || return
    echo "🔍 Revisando $dir..."
    chown -R 1000:1000 "$dir"; cd "$dir"
    git fetch
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u})
    if [[ "$LOCAL" == "$REMOTE" && "$force" != "force" ]]; then
        echo "✔️ Sin cambios."
        cd ..; return
    fi
    [[ "$LOCAL" != "$REMOTE" ]] && git pull || echo "⏩ Forzando build..."
    cd ..; chown -R 1000:1000 "$dir"; cd "$dir"
    [ ! -f Dockerfile ] && echo "🚫 No hay Dockerfile." && return
    IMAGE="${DOCKER_REGISTRY}/$(basename $PWD)"
    TAG_DATE=$(date +%d%m%Y%H%M%S)
    docker build -t "$IMAGE:latest" -t "$IMAGE:$TAG_DATE" .
    docker_login
    docker push "$IMAGE:latest" && docker push "$IMAGE:$TAG_DATE"
    docker rmi "$IMAGE:latest" "$IMAGE:$TAG_DATE"
    docker system prune -f
    cd ..
}

# --ci modo
if [[ "${1:-}" == "--ci" ]]; then
    CI_DIR="${2:-}"; FORCE="${3:-}"
    [ -z "$CI_DIR" ] && echo "❗Falta carpeta para CI." && exit 2
    [[ "$FORCE" == "-f" || "$FORCE" == "--force" ]] && build_and_push_image "$CI_DIR" force | tee -a update.log || build_and_push_image "$CI_DIR" | tee -a update.log
    exit $?
fi

# --login manual docker
if [[ "${1:-}" == "--login" ]]; then
    docker_login | tee -a update.log; exit $?
fi

# Recorrer subcarpetas y construir
for dir in */; do
    build_and_push_image "$dir" | tee -a update.log
done

# Agregar cron si no existe
CRON_JOB="0 6 * * * cd $(pwd) && sh ./update.sh >> update.log 2>&1"
crontab -l 2>/dev/null | grep -F "$CRON_JOB" >/dev/null || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

# Reiniciar crond
if command -v service &>/dev/null; then
    service crond restart
else
    echo "⚠️ No se pudo reiniciar crond (service no disponible)."
fi
