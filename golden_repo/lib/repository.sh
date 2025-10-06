#!/bin/bash

################################################################################
# Módulo de Repositorio
#
# Gestiona las operaciones sobre el repositorio Git: clonación, configuración,
# actualización de metadata, commits y push de cambios.
################################################################################

################################################################################
# Clona el repositorio en un directorio local
#
# Crea un directorio basado en el nombre del repositorio y clona el código
# usando la URL con autenticación. Si el directorio ya existe, lo elimina.
#
# Variables requeridas:
#   - CLONE_URL: URL de clonación con autenticación
#
# Variables exportadas:
#   - CLONE_DIR: Directorio donde se clonó el repositorio
#
# Retorna:
#   0 si el repositorio se clonó exitosamente
#   1 si hubo algún error
################################################################################
clone_repository() {
    local clone_dir
    
    log_info "Preparando para clonar repositorio..."
    
    if ! validate_env_var "CLONE_URL"; then
        send_notification_if_available "error" "CLONE_URL no está definida"
        return 1
    fi
    
    # Obtener nombre del directorio desde la URL
    clone_dir=$(basename -s .git "$CLONE_URL")
    
    # Limpiar directorio si ya existe
    if [ -d "$clone_dir" ]; then
        log_warn "Directorio $clone_dir ya existe, eliminándolo..."
        rm -rf "$clone_dir"
    fi
    
    export CLONE_DIR="$clone_dir"
    
    log_info "Clonando repositorio en: $CLONE_DIR"
    send_notification_if_available "info" "Clonando repositorio en directorio $CLONE_DIR"
    
    # Clonar repositorio
    git clone "$CLONE_URL" "$CLONE_DIR"
    
    if [ $? -ne 0 ]; then
        log_error "Fallo al clonar el repositorio desde GitHub"
        rm -rf "$CLONE_DIR" 2>/dev/null
        send_notification_if_available "error" "Git clone falló"
        return 1
    fi
    
    log_success "Repositorio clonado exitosamente en: $CLONE_DIR"
    send_notification_if_available "info" "Repositorio clonado exitosamente"
    
    return 0
}

################################################################################
# Configura las credenciales de Git en el repositorio clonado
#
# Establece el nombre de usuario y email para los commits realizados
# por el agente automatizado.
#
# Variables requeridas:
#   - CLONE_DIR: Directorio del repositorio clonado
#
# Retorna:
#   0 si la configuración fue exitosa
#   1 si hubo algún error
################################################################################
configure_git_credentials() {
    log_info "Configurando credenciales de Git..."
    
    if ! validate_env_var "CLONE_DIR"; then
        send_notification_if_available "error" "CLONE_DIR no está definido"
        return 1
    fi
    
    if [ ! -d "$CLONE_DIR" ]; then
        log_error "Directorio del repositorio no existe: $CLONE_DIR"
        send_notification_if_available "error" "Directorio del repositorio no válido"
        return 1
    fi
    
    # Cambiar al directorio del repositorio
    cd "$CLONE_DIR" || {
        log_error "No se pudo cambiar al directorio del repositorio"
        send_notification_if_available "error" "Fallo al cambiar a directorio del repositorio"
        return 1
    }
    
    # Configurar usuario y email de Git
    git config user.name "null-platform-agent"
    git config user.email "agent@null-platform.com"
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo configurar las credenciales de Git"
        send_notification_if_available "error" "Fallo al configurar credenciales de Git"
        return 1
    fi
    
    log_success "Credenciales de Git configuradas (user: null-platform-agent)"
    send_notification_if_available "info" "Credenciales de Git configuradas exitosamente"
    
    return 0
}

################################################################################
# Actualiza el archivo metadata.json con información de la aplicación
#
# Obtiene la metadata actual de la aplicación desde NullPlatform, le agrega
# un timestamp y la guarda en el archivo metadata.json en el repositorio.
#
# Variables requeridas:
#   - APP_ID: ID de la aplicación
#
# Variables exportadas:
#   - METADATA_TIMESTAMP: Timestamp de la actualización
#
# Retorna:
#   0 si la metadata se actualizó exitosamente
#   1 si hubo algún error
################################################################################
update_metadata() {
    local metadata timestamp
    
    log_info "Actualizando archivo metadata.json..."
    
    if ! validate_env_var "APP_ID"; then
        send_notification_if_available "error" "APP_ID no está definido"
        return 1
    fi
    
    # Obtener metadata actual de la aplicación
    log_info "Obteniendo metadata desde NullPlatform..."
    metadata=$(np application read --id "$APP_ID" --format json --query .metadata)
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo obtener metadata de la aplicación"
        send_notification_if_available "error" "Fallo al obtener metadata de la aplicación"
        return 1
    fi
    
    # Generar timestamp
    timestamp=$(get_iso_timestamp)
    
    # Agregar timestamp a la metadata y guardar en archivo
    echo "$metadata" | jq --arg now "$timestamp" '. + {timestamp: $now}' > metadata.json
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo crear el archivo metadata.json"
        send_notification_if_available "error" "Fallo al crear archivo metadata.json"
        return 1
    fi
    
    export METADATA_TIMESTAMP="$timestamp"
    log_success "Metadata actualizada con timestamp: $METADATA_TIMESTAMP"
    send_notification_if_available "info" "Metadata actualizada exitosamente con timestamp: $METADATA_TIMESTAMP"
    
    return 0
}

################################################################################
# Realiza commit y push de los cambios al repositorio remoto
#
# Agrega el archivo metadata.json al staging area, crea un commit con un
# mensaje descriptivo y hace push a la rama actual en el repositorio remoto.
#
# Variables requeridas:
#   - METADATA_TIMESTAMP: Timestamp de la actualización (opcional)
#
# Retorna:
#   0 si el commit y push fueron exitosos
#   1 si hubo algún error
################################################################################
commit_and_push() {
    local branch error_output
    
    # Asegurar que METADATA_TIMESTAMP esté definido
    if [ -z "${METADATA_TIMESTAMP:-}" ]; then
        log_warn "METADATA_TIMESTAMP no definido, generando uno nuevo"
        export METADATA_TIMESTAMP=$(get_iso_timestamp)
    fi
    
    log_info "Realizando commit y push de cambios..."
    send_notification_if_available "info" "Realizando commit y push: Timestamp $METADATA_TIMESTAMP"
    
    # Agregar archivo al staging
    git add metadata.json
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo agregar metadata.json al staging area"
        send_notification_if_available "error" "Fallo al agregar archivo al staging"
        return 1
    fi
    
    # Crear commit
    log_info "Creando commit..."
    git commit -m "Auto: update metadata at $METADATA_TIMESTAMP (UTC)"
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo crear el commit"
        send_notification_if_available "error" "Git commit falló"
        return 1
    fi
    
    # Obtener nombre de la rama actual
    branch=$(git rev-parse --abbrev-ref HEAD)
    log_info "Haciendo push a rama: $branch"
    
    # Hacer push al repositorio remoto
    error_output=$(git push --set-upstream origin "$branch" 2>&1)
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo hacer push al repositorio remoto"
        log_error "Detalle del error: $error_output"
        send_notification_if_available "error" "Git push falló en rama ($branch). Detalle: $error_output"
        return 1
    fi
    
    log_success "Cambios enviados exitosamente al repositorio remoto (rama: $branch)"
    send_notification_if_available "info" "Cambios committed y pusheados exitosamente"
    
    return 0
}