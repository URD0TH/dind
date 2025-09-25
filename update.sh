#!/bin/sh
# /repos/update.sh
set -eu

# funcion que valida si esta logeado a github y si no lo esta, lo logea
git_status() {
    if ! command -v gh >/dev/null; then
        echo "❌ GitHub CLI (gh) no está instalado."
        exit 1
    fi
    echo "🔐 Verificando autenticación con GitHub CLI..."
    if ! gh auth status >/dev/null 2>&1; then
        echo "⚠️ No has iniciado sesión. Ejecuta: gh auth login"
        exit 1
    else
        echo "✅ Autenticación OK..."
    fi
}

# Relanzar en bash si se desea (comentado porque queremos compatibilidad con sh)
# if [ -z "${BASH_VERSION:-}" ] && command -v bash >/dev/null; then
#     exec bash "$0" "$@"
# fi

# Verificar opción --git o -g
if [ "${1:-}" = "--git" ] || [ "${1:-}" = "-g" ]; then
    if ! command -v gh >/dev/null; then
        echo "❌ GitHub CLI (gh) no está instalado."
        exit 1
    fi
    echo "🔐 Verificando autenticación con GitHub CLI..."
    if ! gh auth status >/dev/null 2>&1; then
        echo "⚠️ No has iniciado sesión. Ejecuta: gh auth login"
        exit 1
    fi
    echo "✅ Autenticación OK. Configurando Git con gh como helper..."
    git config --global credential.helper '!gh auth git-credential'
    echo "Helper actual: $(git config --global --get credential.helper)"
    gh auth login
    exit 0
fi

# Cargar .env o solicitarlo
if [ -f ".env" ]; then
    set -a
    . ./.env
    set +a
else
    echo "⚠️ .env no encontrado. Solicitando datos..."
    echo -n "DOCKER_USER: "; read DOCKER_USER
    echo -n "DOCKER_PASSWORD: "; read -r DOCKER_PASSWORD
    echo -n "DOCKER_REGISTRY: "; read DOCKER_REGISTRY
    {
        echo "DOCKER_USER=$DOCKER_USER"
        echo "DOCKER_PASSWORD=$DOCKER_PASSWORD"
        echo "DOCKER_REGISTRY=$DOCKER_REGISTRY"
    } > .env
    set -a
    . ./.env
    set +a
fi

# Asegurar /usr/sbin en PATH (para crond)
PATH=$PATH:/usr/sbin
export PATH

# Validar y/o instalar paquetes requeridos
for pkg in git curl; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        echo "⏳ Instalando $pkg..."
        apk update && apk add --no-cache "$pkg"
    else
        echo "✅ $pkg ya instalado."
    fi
done

if ! command -v crond >/dev/null 2>&1; then
    echo "⏳ Instalando cronie..."
    apk update && apk add --no-cache cronie
else
    echo "✅ cronie ya instalado."
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "⏳ Instalando GitHub CLI (gh)..."
    apk update && apk add --no-cache github-cli
else
    echo "✅ GitHub CLI (gh) ya instalado."
fi

# Asegurar crond corriendo
if ! pgrep crond >/dev/null 2>&1; then
    echo "▶️ Iniciando crond..."
    crond
fi

# Asegurar /root/.cache para evitar error en crontab
mkdir -p /root/.cache

# Marcar repos como seguros para git
for repo in /repos/*; do
    if [ -d "$repo/.git" ]; then
        if ! git config --global --get-all safe.directory | grep -Fq "$repo"; then
            echo "📁 Marcando $repo como directorio seguro..."
            git config --global --add safe.directory "$repo"
            
        else
            echo "✅ $repo ya está marcado como seguro."
        fi
    fi
done

# Función docker_login (POSIX compatible)
docker_login() {
    if ! docker info 2>&1 | grep -q "$DOCKER_REGISTRY"; then
        echo "🛂 Conectando a $DOCKER_REGISTRY..."
        echo "$DOCKER_PASSWORD" | docker login "$DOCKER_REGISTRY" -u "$DOCKER_USER" --password-stdin
    fi
}

# Función build_and_push_image (POSIX compatible)
build_and_push_image() {
    dir="$1"
    force="${2:-}"
    echo "DEBUG: Inside build_and_push_image for $dir"
    git_status
    echo "DEBUG: After git_status for $dir"

    if [ ! -d "$dir/.git" ]; then
        echo "DEBUG: Not a git repository: $dir"
        return
    fi

    echo "🔍 Revisando $dir..."
    chown -R 1000:1000 "$dir"
    cd "$dir"

    git fetch
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u} || echo "")

    if [ "$LOCAL" = "$REMOTE" ] && [ "$force" != "force" ]; then
        echo "✔️ Sin cambios."
        cd ..
        return
    fi

    if [ "$LOCAL" != "$REMOTE" ]; then
        git pull
    else
        echo "⏩ Forzando build..."
    fi

    cd ..
    chown -R 1000:1000 "$dir"
    cd "$dir"

    if [ ! -f Dockerfile ]; then
        echo "🚫 No hay Dockerfile."
        return
    fi

    IMAGE="${DOCKER_REGISTRY}/$(basename "$PWD")"
    TAG_DATE=$(date +%d%m%Y%H%M%S)

    docker build -t "$IMAGE:latest" -t "$IMAGE:$TAG_DATE" .
    docker_login
    docker push "$IMAGE:latest"
    docker push "$IMAGE:$TAG_DATE"
    docker rmi "$IMAGE:latest" "$IMAGE:$TAG_DATE"
    docker system prune -f
    cd ..
}

# Modo --ci
if [ "${1:-}" = "--ci" ]; then
    CI_DIR="${2:-}"
    FORCE="${3:-}"
    if [ -z "$CI_DIR" ]; then
        echo "❗Falta carpeta para CI."
        exit 2
    fi

    if [ "$FORCE" = "-f" ] || [ "$FORCE" = "--force" ]; then
        build_and_push_image "$CI_DIR" force | tee -a update.log
    else
        build_and_push_image "$CI_DIR" | tee -a update.log
    fi
    exit $?
fi

# Modo --login
if [ "${1:-}" = "--login" ]; then
    docker_login | tee -a update.log
    exit $?
fi

# Recorrer subcarpetas y construir imágenes
echo "DEBUG: About to start the main loop."
for dir in */; do
    echo "DEBUG: Processing directory: $dir"
    build_and_push_image "$dir" | tee -a update.log
done
echo "DEBUG: Finished the main loop."

# Agregar cron si no existe
CRON_JOB="0 6 * * * cd $(pwd) && sh ./update.sh >> update.log 2>&1"
if ! crontab -l 2>/dev/null | grep -F "$CRON_JOB" >/dev/null; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
fi

# Reiniciar crond si es posible
if command -v crond >/dev/null 2>&1; then
    if [ -f /var/run/crond.pid ]; then
        rm -f /var/run/crond.pid
    fi
    pkill crond || true
    sleep 1
    /usr/sbin/crond
else
    echo "⚠️ No se pudo reiniciar crond (comando no disponible)."
fi