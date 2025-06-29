
#!/bin/bash
# auto_update.sh
# Mejoras: manejo de errores y carga robusta de variables de entorno
set -euo pipefail
trap 'echo "Error en la línea $LINENO"; exit 1' ERR

# Detectar bash y relanzar si está disponible
if [ -z "${BASH_VERSION:-}" ] && command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
fi

# Cargar variables de entorno de forma robusta
if [ -f ".env" ]; then
    set -a
    . .env
    set +a
else
    echo "Archivo .env no encontrado."
    exit 1
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

# Recorrer subcarpetas
for dir in */ ; do
    [ -d "$dir/.git" ] || continue
    echo "cambiando  usuario directorio: $dir"
    chown -R 1000:1000 "$dir"  # Cambiar propietario a usuario 1000:1000 (root en Docker)
    cd "$dir"
    echo "Revisando $dir"
    git fetch
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse @{u})
    if [ "$LOCAL" = "$REMOTE" ]; then
        echo "No hay cambios en $dir"
        cd ..
        continue
    else
        echo "Actualizaciones detectadas en $dir, actualizando..."
        git pull
        cd ..
        chown -R 1000:1000 "$dir"  # Cambiar propietario a usuario 1000:1000 (root en Docker)
        # Verificar si hay un Dockerfile
        if [ ! -f "$dir/Dockerfile" ]; then
            echo "No se encontró Dockerfile en $dir, saltando..."
            continue
        fi
        cd "$dir"
        # Construir imagen Docker
        IMAGE_NAME="${DOCKER_REGISTRY}/$(basename $PWD)"
        TAG_LATEST="latest"
        TAG_DATE=$(date +%d%m%Y%H%M%S)
        docker build -t "$IMAGE_NAME:$TAG_LATEST" -t "$IMAGE_NAME:$TAG_DATE" .
        docker_login
        docker push "$IMAGE_NAME:$TAG_LATEST"
        docker push "$IMAGE_NAME:$TAG_DATE"
        # Limpiar imágenes locales
        docker rmi "$IMAGE_NAME:$TAG_LATEST" "$IMAGE_NAME:$TAG_DATE"
        # Limpiar archivos temporales de Docker
        docker system prune -f
    fi
    cd ..
done

# Agregar al cron si no existe
CRON_JOB="0 6 * * * cd $(pwd) && sh ./auto_update.sh >> auto_update.log 2>&1"
CRON_EXISTS=$(crontab -l 2>/dev/null | grep -F "$CRON_JOB" || true)
if [ -z "$CRON_EXISTS" ]; then
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "Tarea programada en cron para las 6:00 AM America/Santiago."
fi

# Reiniciar cron para aplicar cambios
if command -v service >/dev/null 2>&1; then
    service crond restart
else
    echo "No se pudo reiniciar el servicio crond."
fi