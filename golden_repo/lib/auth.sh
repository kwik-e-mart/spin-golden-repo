#!/bin/bash

################################################################################
# Módulo de Autenticación
#
# Gestiona la autenticación con NullPlatform y la extracción de información
# de aplicaciones. Incluye generación de tokens y carga de variables.
################################################################################

################################################################################
# Genera token de acceso de NullPlatform
#
# Utiliza la API key configurada en NP_API_KEY para obtener un token de acceso.
# El token se almacena en la variable de entorno NP_TOKEN.
#
# Variables requeridas:
#   - NP_API_KEY: API key de NullPlatform
#
# Variables exportadas:
#   - NP_TOKEN: Token de acceso generado
#
# Retorna:
#   0 si el token se generó exitosamente
#   1 si hubo algún error
################################################################################
generate_np_token() {
    local response token
    
    log_info "Generando token de acceso de NullPlatform..."
    
    # Validar que la API key esté configurada
    if ! validate_env_var "NP_API_KEY"; then
        send_notification_if_available "error" "NP_API_KEY no está configurada"
        return 1
    fi
    
    # Realizar petición a la API
    response=$(curl -s --request POST \
        --url https://api.nullplatform.com/token \
        --header 'content-type: application/json' \
        --data "{\"api_key\": \"$NP_API_KEY\"}")
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo conectar a la API de NullPlatform"
        send_notification_if_available "error" "Error de conexión con API de NullPlatform"
        return 1
    fi
    
    # Extraer token de la respuesta
    token=$(extract_json_value "$response" '.access_token')
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo obtener el token de acceso de la respuesta"
        send_notification_if_available "error" "Token de NullPlatform inválido o vacío"
        return 1
    fi
    
    export NP_TOKEN="$token"
    log_success "Token de NullPlatform generado exitosamente"
    send_notification_if_available "info" "Token de NullPlatform generado exitosamente"
    
    return 0
}

################################################################################
# Extrae el ID de la aplicación desde NOTIFICATION_NRN
#
# Parsea el NRN (NullPlatform Resource Name) para obtener el ID de la aplicación.
# Formato esperado: nrn:*:application=<APP_ID>:*
#
# Variables requeridas:
#   - NOTIFICATION_NRN: NRN que contiene el ID de la aplicación
#
# Variables exportadas:
#   - APP_ID: ID de la aplicación extraído
#
# Retorna:
#   0 si el ID se extrajo exitosamente
#   1 si hubo algún error
################################################################################
extract_app_id() {
    local app_id
    
    log_info "Extrayendo ID de aplicación desde NOTIFICATION_NRN..."
    
    if ! validate_env_var "NOTIFICATION_NRN"; then
        send_notification_if_available "error" "NOTIFICATION_NRN no está definida"
        return 1
    fi
    
    # Extraer APP_ID usando awk
    app_id=$(echo "$NOTIFICATION_NRN" | awk -F'application=' '{print $2}')
    
    if [ -z "$app_id" ]; then
        log_error "No se pudo extraer el ID de aplicación desde el NRN"
        send_notification_if_available "error" "Fallo al parsear APP_ID desde NOTIFICATION_NRN"
        return 1
    fi
    
    export APP_ID="$app_id"
    log_success "ID de aplicación extraído: $APP_ID"
    send_notification_if_available "info" "ID de aplicación extraído exitosamente: $APP_ID"
    
    return 0
}

################################################################################
# Carga las variables de la aplicación desde NullPlatform
#
# Utiliza la CLI de NullPlatform (np) para leer la información de la aplicación
# y exportar todas sus propiedades como variables de entorno con el prefijo APP_.
#
# Variables requeridas:
#   - APP_ID: ID de la aplicación
#
# Variables exportadas:
#   - APP_*: Todas las propiedades de la aplicación con prefijo APP
#
# Retorna:
#   0 si las variables se cargaron exitosamente
#   1 si hubo algún error
################################################################################
load_app_variables() {
    log_info "Cargando variables de la aplicación desde NullPlatform..."
    
    if ! validate_env_var "APP_ID"; then
        send_notification_if_available "error" "APP_ID no está definido"
        return 1
    fi
    
    # Ejecutar comando np y evaluar su salida para exportar variables
    eval "$(np application read --id "$APP_ID" --format bash --bash-prefix APP)"
    
    if [ $? -ne 0 ]; then
        log_error "Fallo al ejecutar comando: np application read"
        send_notification_if_available "error" "Comando 'np application read' falló"
        return 1
    fi
    
    log_success "Variables de aplicación cargadas con prefijo APP_"
    send_notification_if_available "info" "Variables de aplicación cargadas exitosamente"
    
    return 0
}
