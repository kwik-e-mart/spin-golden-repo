#!/bin/bash

# Función para generar el token de acceso de NullPlatform
# En caso de que algún curl responda 401, debe volver a invocarse
generate_np_token() {
    local response

    echo "Generando token de acceso de NullPlatform..."

    response=$(curl -s --request POST \
        --url https://api.nullplatform.com/token \
        --header 'content-type: application/json' \
        --data "{\"api_key\": \"$NP_API_KEY\"}")

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo conectar a la API de NullPlatform" >&2
        send_notification_if_available "error" "Error al generar token NP: No se pudo conectar a la API"
        return 1
    fi

    NP_TOKEN=$(echo "$response" | jq -r '.access_token')

    if [ "$NP_TOKEN" = "null" ] || [ -z "$NP_TOKEN" ]; then
        echo "Error: No se pudo obtener el token de acceso" >&2
        send_notification_if_available "error" "Error al generar token NP: Token inválido o vacío"
        return 1
    fi

    echo "Token generado exitosamente"
    send_notification_if_available "info" "Token de NullPlatform generado exitosamente"
    return 0
}

# Función auxiliar para enviar notificaciones solo si las variables están disponibles
send_notification_if_available() {
    local level="$1"
    local message="$2"

    if [ -n "$NOTIFICATION_CALLBACK_URL" ] && [ -n "$NP_TOKEN" ]; then
        local timestamp
        timestamp=$(date -Iseconds)

        curl -s -X POST "$NOTIFICATION_CALLBACK_URL/message" \
            -H 'Content-Type: application/json' \
            -H "Authorization: Bearer $NP_TOKEN" \
            -d "{\"level\": \"$level\", \"message\": \"$message en $timestamp\"}" >/dev/null 2>&1
    fi
}

# Función para extraer el ID de la aplicación del NRN de notificación
extract_app_id() {
    if [ -z "$NOTIFICATION_NRN" ]; then
        echo "Error: Variable NOTIFICATION_NRN no está definida" >&2
        send_notification_if_available "error" "Error al extraer APP_ID: Variable NOTIFICATION_NRN no definida"
        return 1
    fi

    APP_ID=$(echo "$NOTIFICATION_NRN" | awk -F'application=' '{print $2}')

    if [ -z "$APP_ID" ]; then
        echo "Error: No se pudo extraer el ID de la aplicación" >&2
        send_notification_if_available "error" "Error al extraer APP_ID: No se pudo parsear desde NOTIFICATION_NRN"
        return 1
    fi

    echo "ID de aplicación extraído: $APP_ID"
    send_notification_if_available "info" "ID de aplicación extraído exitosamente: $APP_ID"
    return 0
}

# Función para leer información de la aplicación y exponerla como variables de entorno
# Agrega el prefijo APP a todas las keys del JSON de respuesta
load_app_variables() {
    if [ -z "$APP_ID" ]; then
        echo "Error: APP_ID no está definido" >&2
        send_notification_if_available "error" "Error al cargar variables de app: APP_ID no definido"
        return 1
    fi

    echo "Cargando variables de la aplicación..."

    eval "$(np application read --id "$APP_ID" --format bash --bash-prefix APP)"

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo cargar la información de la aplicación" >&2
        send_notification_if_available "error" "Error al cargar variables de app: Falló comando np application read"
        return 1
    fi

    echo "Variables de aplicación cargadas con prefijo APP"
    send_notification_if_available "info" "Variables de aplicación cargadas exitosamente con prefijo APP"
    return 0
}

# Función para extraer la organización del repositorio
extract_organization() {
    if [ -z "$APP_REPOSITORY_URL" ]; then
        echo "Error: Variable APP_REPOSITORY_URL no está definida" >&2
        send_notification_if_available "error" "Error al extraer organización: APP_REPOSITORY_URL no definida"
        return 1
    fi

    org=$(cut -d'/' -f4 <<< "$APP_REPOSITORY_URL")

    if [ -z "$org" ]; then
        echo "Error: No se pudo extraer la organización del repositorio" >&2
        send_notification_if_available "error" "Error al extraer organización: No se pudo parsear desde APP_REPOSITORY_URL"
        return 1
    fi

    echo "Organización extraída: $org"
    export GITHUB_ORG="$org"
    send_notification_if_available "info" "Organización de GitHub extraída exitosamente: $org"
    return 0
}

# Función para crear JWT y generar token de GitHub
generate_github_token() {
    local now exp header payload signature jwt response token secret_json app_id installation_id private_key

    secret_json=$(aws secretsmanager get-secret-value --secret-id "null-platform/golden-repos/gh-orgs/${org}" | jq -r '.SecretString | fromjson')

    app_id=$(jq -r '.app_id' <<< "$secret_json")
    installation_id=$(jq -r '.installation_id' <<< "$secret_json")
    private_key=$(mktemp "private_key_XXXXXX.pem")
    echo -e "$(jq -r '.private_key' <<< "$secret_json")" > "$private_key"

    echo "Generando token de GitHub..."

    # Crear JWT
    now=$(date +%s)
    exp=$((now + 540))

    header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$now" "$exp" "$app_id" | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -sign "$private_key" | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo crear la firma JWT" >&2
        send_notification_if_available "error" "Error al generar token GitHub: No se pudo crear firma JWT"
        return 1
    fi

    jwt="${header}.${payload}.${signature}"

    # Obtener token de acceso
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${installation_id}/access_tokens")

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo conectar a la API de GitHub" >&2
        send_notification_if_available "error" "Error al generar token GitHub: No se pudo conectar a la API"
        return 1
    fi

    token=$(echo "$response" | jq -r '.token')

    if [ "$token" = "null" ] || [ -z "$token" ]; then
        echo "Error: No se pudo obtener el token de GitHub" >&2
        echo "Respuesta: $response" >&2
        send_notification_if_available "error" "Error al generar token GitHub: Token inválido o vacío"
        return 1
    fi

    export GITHUB_TOKEN="$token"
    echo "Token de GitHub generado exitosamente"
    send_notification_if_available "info" "Token de GitHub generado exitosamente"
    return 0
}

# Función para preparar URLs de clonación
prepare_clone_urls() {
    if [ -z "$APP_REPOSITORY_URL" ] || [ -z "$GITHUB_TOKEN" ]; then
        echo "Error: Variables requeridas no están definidas" >&2
        send_notification_if_available "error" "Error al preparar URLs: Variables APP_REPOSITORY_URL o GITHUB_TOKEN faltantes"
        return 1
    fi

    local repo_path clone_url

    repo_path="${APP_REPOSITORY_URL#https://github.com/}.git"
    clone_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${repo_path}"

    export REPO_PATH="$repo_path"
    export CLONE_URL="$clone_url"

    echo "URLs de clonación preparadas"
    send_notification_if_available "info" "URLs de clonación preparadas exitosamente"
    return 0
}

# Función para clonar el repositorio en un directorio temporal
clone_repository() {
    if [ -z "$CLONE_URL" ]; then
        echo "Error: URL de clonación no está definida" >&2
        send_notification_if_available "error" "Error al clonar repositorio: URL de clonación no definida"
        return 1
    fi

    CLONE_DIR=$(basename -s .git "$CLONE_URL")
    # Remove existing directory if present
    if [ -d "$CLONE_DIR" ]; then
        rm -rf "$CLONE_DIR"
    fi

    send_notification_if_available "info" "Clonando repo en directorio $CLONE_DIR"

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo crear directorio temporal" >&2
        send_notification_if_available "error" "Error al clonar repositorio: No se pudo crear directorio temporal"
        return 1
    fi

    git clone "$CLONE_URL" "$CLONE_DIR"

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo clonar el repositorio" >&2
        rm -rf "$CLONE_DIR" 2>/dev/null
        send_notification_if_available "error" "Error al clonar repositorio: Git clone falló"
        return 1
    fi

    echo "Repositorio clonado en: $CLONE_DIR"
    send_notification_if_available "info" "Repositorio clonado exitosamente en directorio temporal"
    return 0
}

# Función para configurar credenciales de Git
configure_git_credentials() {
    if [ -z "$CLONE_DIR" ] || [ ! -d "$CLONE_DIR" ]; then
        echo "Error: Directorio del repositorio no válido" >&2
        send_notification_if_available "error" "Error al configurar Git: Directorio del repositorio no válido"
        return 1
    fi

    echo "Configurando credenciales de Git..."

    cd "$CLONE_DIR" || {
        echo "Error: No se pudo cambiar al directorio del repositorio" >&2
        send_notification_if_available "error" "Error al configurar Git: No se pudo cambiar al directorio del repositorio"
        return 1
    }

    git config user.name "null-platform-agent"
    git config user.email "agent@null-platform.com"

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo configurar las credenciales de Git" >&2
        send_notification_if_available "error" "Error al configurar Git: No se pudo configurar credenciales"
        return 1
    fi

    echo "Credenciales de Git configuradas"
    send_notification_if_available "info" "Credenciales de Git configuradas exitosamente"
    return 0
}

# Función para crear y actualizar metadata.json
update_metadata() {
    if [ -z "$APP_ID" ]; then
        echo "Error: APP_ID no está definido" >&2
        send_notification_if_available "error" "Error al actualizar metadata: APP_ID no definido"
        return 1
    fi

    local metadata timestamp

    echo "Actualizando metadata..."

    metadata=$(np application read --id "$APP_ID" --format json --query .metadata)

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo obtener metadata de la aplicación" >&2
        send_notification_if_available "error" "Error al actualizar metadata: No se pudo obtener metadata de la aplicación"
        return 1
    fi

    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "$metadata" | jq --arg now "$timestamp" '. + {timestamp: $now}' > metadata.json

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo crear el archivo metadata.json" >&2
        send_notification_if_available "error" "Error al actualizar metadata: No se pudo crear archivo metadata.json"
        return 1
    fi

    echo "Metadata actualizado con timestamp: $timestamp"
    export METADATA_TIMESTAMP="$timestamp"
    send_notification_if_available "info" "Metadata actualizada exitosamente con timestamp: $METADATA_TIMESTAMP"
    return 0
}

# Función para hacer commit y push de los cambios
commit_and_push() {
    if [ -z "$METADATA_TIMESTAMP" ]; then
        echo "Error: Timestamp de metadata no está definido" >&2
        send_notification_if_available "warn" "Error en commit y push: Timestamp de metadata no definido"
        export METADATA_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    fi

    echo "Realizando commit y push..."
    send_notification_if_available "info" "Realizando commit y push: Timestamp $METADATA_TIMESTAMP"

    git add metadata.json

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo agregar metadata.json al staging" >&2
        send_notification_if_available "error" "Error en commit y push: No se pudo agregar archivo al staging"
        return 1
    fi

    git commit -m "Auto: update metadata at $METADATA_TIMESTAMP (UTC)"

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo hacer commit de los cambios" >&2
        send_notification_if_available "error" "Error en commit y push: Git commit falló"
        return 1
    fi

    branch=$(git rev-parse --abbrev-ref HEAD)
    error_output=$(git push --set-upstream origin "$branch" 2>&1)
    if [ $error_output -ne 0 ]; then
        send_notification_if_available "error" "Error en commit y push on branch ($branch) Git push falló. Detalle: $error_output"
        return 1
    fi

    echo "Cambios enviados exitosamente al repositorio"
    send_notification_if_available "info" "Cambios committed y pusheados exitosamente al repositorio"
    return 0
}

# Función para enviar mensaje de notificación
send_notification_message() {
    local level="${1:-info}"
    local message="${2:-Proceso ejecutado}"

    if [ -z "$NOTIFICATION_CALLBACK_URL" ] || [ -z "$NP_TOKEN" ]; then
        echo "Error: Variables de notificación no están definidas" >&2
        return 1
    fi

    local timestamp
    timestamp=$(date -Iseconds)

    curl -s -X POST "$NOTIFICATION_CALLBACK_URL/message" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $NP_TOKEN" \
        -d "{\"level\": \"$level\", \"message\": \"$message en $timestamp\"}"

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo enviar el mensaje de notificación" >&2
        return 1
    fi

    echo "Mensaje de notificación enviado: $level - $message"
    return 0
}

# Función para enviar estado final del proceso
send_final_status() {
    local status="${1:-success}"
    local execution_status="${2:-success}"

    if [ -z "$NOTIFICATION_CALLBACK_URL" ] || [ -z "$NP_TOKEN" ]; then
        echo "Error: Variables de notificación no están definidas" >&2
        return 1
    fi

    curl -s -X PATCH \
        "$NOTIFICATION_CALLBACK_URL" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $NP_TOKEN" \
        -d "{\"status\": \"$status\", \"execution_status\": \"$execution_status\"}"

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo enviar el estado final" >&2
        return 1
    fi

    echo "Estado final enviado: $status - $execution_status"
    return 0
}

# Función de limpieza para eliminar directorios temporales
cleanup() {
    if [ -n "$CLONE_DIR" ] && [ -d "$CLONE_DIR" ]; then
        echo "Limpiando directorio temporal: $CLONE_DIR"
        rm -rf "$CLONE_DIR"
    fi
}

# Función para manejar errores y enviar notificación de fallo
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"

    echo "ERROR: $error_message" >&2

    # Intentar enviar notificación de error si las variables están disponibles
    if [ -n "$NOTIFICATION_CALLBACK_URL" ] && [ -n "$NP_TOKEN" ]; then
        send_notification_message "error" "Error en script: $error_message"
        send_final_status "failed" "failed"
    fi

    cleanup
    exit "$exit_code"
}

# Función principal que ejecuta todo el proceso
main() {
    echo "Iniciando proceso principal..."

    # Configurar trap para limpieza en caso de error
    trap cleanup EXIT

    # Ejecutar todas las funciones en orden
    generate_np_token || handle_error "No se pudo generar el token de NullPlatform"

    extract_app_id || handle_error "No se pudo extraer el ID de la aplicación"

    load_app_variables || handle_error "No se pudo cargar las variables de la aplicación"

    extract_organization || handle_error "No se pudo extraer la organización"

    generate_github_token || handle_error "No se pudo generar el token de GitHub"

    prepare_clone_urls || handle_error "No se pudo preparar las URLs de clonación"

    clone_repository || handle_error "No se pudo clonar el repositorio"

    configure_git_credentials || handle_error "No se pudo configurar las credenciales de Git"

    update_metadata || handle_error "No se pudo actualizar el metadata"

    commit_and_push || handle_error "No se pudo hacer commit y push de los cambios"

    # Enviar notificaciones de éxito
    send_notification_message "info" "Proceso completado exitosamente"
    send_final_status "success" "success"

    echo "Proceso principal completado exitosamente"
    cleanup
}

# Ejecutar función principal si el script es llamado directamente
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
