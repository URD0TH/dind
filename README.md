# dind: Imagen Docker personalizada

Este proyecto contiene un `Dockerfile` para construir una imagen basada en `docker:latest` que incluye las siguientes utilidades:

- `git`
- `curl`
- `cronie`

Además, la imagen:
- Crea el directorio `/repos` y lo expone como volumen persistente.
- Copia y ejecuta el script `update.sh` en `/repos/update.sh` durante la construcción, registrando la salida en `/var/log/update_repos.log`.
- Crea el directorio `/root/.cache`.

## Uso

1. Construir la imagen:
   ```sh
   docker build -t dind .
   ```


## Estructura
- `Dockerfile`: Definición de la imagen.
- `update.sh`: Script personalizado que se ejecuta durante el build.

## Notas
- El script `update.sh` debe estar presente en la raíz del proyecto.
- El volumen `/repos` permite persistir y compartir datos entre el host y el contenedor.
