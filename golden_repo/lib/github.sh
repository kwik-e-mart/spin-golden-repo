#!/bin/bash

################################################################################
# Módulo de GitHub
#
# Gestiona la autenticación con GitHub usando GitHub Apps y la preparación
# de URLs de clonación. Incluye generación de JWT y obtención de tokens
# de instalación.
################################################################################

################################################################################
# Extrae la organización desde APP_REPOSITORY_URL
#
# Parsea la URL del repositorio para extraer el nombre de la organización.
# Formato esperado: https://github.com/<org>/<repo>
#
# Variables requeridas:
#   - APP_REPOSITORY_URL: URL del repositorio de GitHub
#
# Variables exportadas:
#   - GITHUB_ORG: Nombre de la organización extraída
#
# Retorna:
#   0 si se extrajo exitosamente
#   1 si hubo algún error
################################################################################
extract_organization() {
    local org
    
    log_info "Extrayendo organización desde APP_REPOSITORY_URL..."
    
    if ! validate_env_var "APP_REPOSITORY_URL"; then
        send_notification_if_available "error" "APP_REPOSITORY_URL no está definida"
        return 1
    fi
    
    # Extraer organización (4to campo separado por /)
    org=$(cut -d'/' -f4 <<< "$APP_REPOSITORY_URL")
    
    if [ -z "$org" ]; then
        log_error "No se pudo extraer la organización de la URL del repositorio"
        send_notification_if_available "error" "Fallo al parsear organización desde APP_REPOSITORY_URL"
        return 1
    fi
    
    export GITHUB_ORG="$org"
    log_success "Organización de GitHub extraída: $GITHUB_ORG"
    send_notification_if_available "info" "Organización de GitHub extraída: $GITHUB_ORG"
    
    return 0
}

################################################################################
# Genera un JWT (JSON Web Token) para GitHub App
#
# Argumentos:
#   $1 - App ID de GitHub
#   $2 - Ruta al archivo de clave privada
#
# Salida:
#   JWT generado (impreso a stdout)
#
# Retorna:
#   0 si se generó exitosamente
#   1 si hubo algún error
################################################################################
generate_github_jwt() {
    local app_id="$1"
    local private_key_file="$2"
    local now exp header payload signature jwt
    
    # Generar timestamps
    now=$(date +%s)
    exp=$((now + 540))  # Token válido por 9 minutos
    
    # Crear header JWT
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | \
             openssl base64 -e | \
             tr -d '=' | \
             tr '/+' '_-' | \
             tr -d '\n')
    
    # Crear payload JWT
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$now" "$exp" "$app_id" | \
              openssl base64 -e | \
              tr -d '=' | \
              tr '/+' '_-' | \
              tr -d '\n')
    
    # Crear firma
    signature=$(echo -n "${header}.${payload}" | \
                openssl dgst -sha256 -sign "$private_key_file" | \
                openssl base64 -e | \
                tr -d '=' | \
                tr '/+' '_-' | \
                tr -d '\n')
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo crear la firma JWT"
        return 1
    fi
    
    # Construir JWT completo
    jwt="${header}.${payload}.${signature}"
    echo "$jwt"
    
    return 0
}

################################################################################
# Genera token de instalación de GitHub App
#
# Obtiene las credenciales de la GitHub App desde AWS Secrets Manager,
# genera un JWT y lo intercambia por un token de instalación.
#
# Variables requeridas:
#   - GITHUB_ORG: Organización de GitHub
#
# Variables exportadas:
#   - GITHUB_TOKEN: Token de instalación generado
#
# Retorna:
#   0 si el token se generó exitosamente
#   1 si hubo algún error
################################################################################
generate_github_token() {
    local secret_json app_id installation_id private_key_file jwt response token
    
    log_info "Generando token de instalación de GitHub App..."
    
    if ! validate_env_var "GITHUB_ORG"; then
        send_notification_if_available "error" "GITHUB_ORG no está definida"
        return 1
    fi
    
    # Obtener credenciales desde AWS Secrets Manager
    log_info "Obteniendo credenciales desde AWS Secrets Manager..."
    secret_json=$(aws secretsmanager get-secret-value \
                  --secret-id "null-platform/golden-repos/gh-orgs/${GITHUB_ORG}" | \
                  jq -r '.SecretString | fromjson')
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo obtener el secreto desde AWS Secrets Manager"
        send_notification_if_available "error" "Fallo al obtener secreto de AWS"
        return 1
    fi
    
    # Extraer valores del secreto
    app_id=$(extract_json_value "$secret_json" '.app_id')
    installation_id=$(extract_json_value "$secret_json" '.installation_id')
    
    if [ $? -ne 0 ] || [ -z "$app_id" ] || [ -z "$installation_id" ]; then
        log_error "No se pudieron extraer app_id o installation_id del secreto"
        send_notification_if_available "error" "Datos incompletos en secreto de AWS"
        return 1
    fi
    
    # Guardar clave privada en archivo temporal
    private_key_file=$(create_temp_file "private_key_XXXXXX.pem")
    if [ $? -ne 0 ]; then
        send_notification_if_available "error" "No se pudo crear archivo temporal para clave privada"
        return 1
    fi
    
    echo -e "$(extract_json_value "$secret_json" '.private_key')" > "$private_key_file"
    
    # Generar JWT
    log_info "Generando JWT para GitHub App (App ID: $app_id)..."
    jwt=$(generate_github_jwt "$app_id" "$private_key_file")
    
    if [ $? -ne 0 ] || [ -z "$jwt" ]; then
        rm -f "$private_key_file"
        send_notification_if_available "error" "No se pudo generar JWT"
        return 1
    fi
    
    # Intercambiar JWT por token de instalación
    log_info "Obteniendo token de instalación (Installation ID: $installation_id)..."
    response=$(curl -s -X POST \
               -H "Authorization: Bearer $jwt" \
               -H "Accept: application/vnd.github+json" \
               "https://api.github.com/app/installations/${installation_id}/access_tokens")
    
    # Limpiar archivo de clave privada
    rm -f "$private_key_file"
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo conectar a la API de GitHub"
        send_notification_if_available "error" "Fallo al conectar con API de GitHub"
        return 1
    fi
    
    # Extraer token de la respuesta
    token=$(extract_json_value "$response" '.token')
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo obtener el token de instalación"
        log_error "Respuesta de API: $response"
        send_notification_if_available "error" "Token de GitHub inválido o vacío"
        return 1
    fi
    
    export GITHUB_TOKEN="$token"
    log_success "Token de instalación de GitHub generado exitosamente"
    send_notification_if_available "info" "Token de GitHub generado exitosamente"
    
    return 0
}

################################################################################
# Prepara las URLs necesarias para clonar el repositorio
#
# Construye la URL de clonación con autenticación integrada usando el token
# de GitHub y extrae el path del repositorio.
#
# Variables requeridas:
#   - APP_REPOSITORY_URL: URL del repositorio
#   - GITHUB_TOKEN: Token de autenticación de GitHub
#
# Variables exportadas:
#   - REPO_PATH: Path del repositorio (org/repo.git)
#   - CLONE_URL: URL completa de clonación con autenticación
#
# Retorna:
#   0 si las URLs se prepararon exitosamente
#   1 si hubo algún error
################################################################################
prepare_clone_urls() {
    local repo_path clone_url
    
    log_info "Preparando URLs de clonación..."
    
    if ! validate_required_vars "APP_REPOSITORY_URL" "GITHUB_TOKEN"; then
        send_notification_if_available "error" "Variables requeridas para URLs no disponibles"
        return 1
    fi
    
    # Extraer path del repositorio (quitar https://github.com/ y agregar .git)
    repo_path="${APP_REPOSITORY_URL#https://github.com/}.git"
    
    # Construir URL de clonación con token
    clone_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${repo_path}"
    
    export REPO_PATH="$repo_path"
    export CLONE_URL="$clone_url"
    
    log_success "URLs de clonación preparadas"
    log_info "Repository path: $REPO_PATH"
    send_notification_if_available "info" "URLs de clonación preparadas exitosamente"
    
    return 0
}
