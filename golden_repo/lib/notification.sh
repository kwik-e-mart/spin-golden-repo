#!/bin/bash

################################################################################
# Módulo de Notificaciones
#
# Gestiona el envío de notificaciones al sistema de callbacks de NullPlatform.
# Incluye mensajes de progreso y actualización de estado final.
################################################################################

################################################################################
# Envía una notificación solo si las variables requeridas están disponibles
#
# Esta función es segura de llamar en cualquier momento, ya que verifica
# la disponibilidad de credenciales antes de intentar enviar.
#
# Argumentos:
#   $1 - Nivel de notificación (info, warn, error, success)
#   $2 - Mensaje de notificación
#
# Variables requeridas:
#   - NOTIFICATION_CALLBACK_URL: URL del endpoint de callbacks
#   - NP_TOKEN: Token de autenticación de NullPlatform
#
# Retorna:
#   0 siempre (no falla aunque no se envíe la notificación)
################################################################################
send_notification_if_available() {
    local level="$1"
    local message="$2"
    
    # Verificar que las variables necesarias estén disponibles
    if [ -z "${NOTIFICATION_CALLBACK_URL:-}" ] || [ -z "${NP_TOKEN:-}" ]; then
        return 0
    fi
    
    local timestamp
    timestamp=$(get_iso_timestamp_seconds)
    
    # Enviar notificación (silenciosamente)
    curl -s -X POST "$NOTIFICATION_CALLBACK_URL/message" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $NP_TOKEN" \
        -d "{\"level\": \"$level\", \"message\": \"$message en $timestamp\"}" \
        >/dev/null 2>&1
    
    return 0
}

################################################################################
# Envía un mensaje de notificación al sistema de callbacks
#
# A diferencia de send_notification_if_available, esta función requiere
# que las variables estén configuradas y reporta errores si fallan.
#
# Argumentos:
#   $1 - Nivel de notificación (info, warn, error, success) - default: info
#   $2 - Mensaje de notificación - default: "Proceso ejecutado"
#
# Variables requeridas:
#   - NOTIFICATION_CALLBACK_URL: URL del endpoint de callbacks
#   - NP_TOKEN: Token de autenticación de NullPlatform
#
# Retorna:
#   0 si la notificación se envió exitosamente
#   1 si hubo algún error
################################################################################
send_notification() {
    local level="${1:-info}"
    local message="${2:-Proceso ejecutado}"
    
    # Validar variables requeridas
    if ! validate_required_vars "NOTIFICATION_CALLBACK_URL" "NP_TOKEN"; then
        log_error "Variables de notificación no están configuradas"
        return 1
    fi
    
    local timestamp response http_code
    timestamp=$(get_iso_timestamp_seconds)
    
    # Enviar notificación y capturar código HTTP
    response=$(curl -s -w "\n%{http_code}" -X POST "$NOTIFICATION_CALLBACK_URL/message" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $NP_TOKEN" \
        -d "{\"level\": \"$level\", \"message\": \"$message en $timestamp\"}")
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo enviar mensaje de notificación"
        return 1
    fi
    
    # Extraer código HTTP de la respuesta
    http_code=$(echo "$response" | tail -n1)
    
    # Verificar código de respuesta
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_info "Notificación enviada: [$level] $message"
        return 0
    else
        log_warn "Notificación enviada pero respuesta inesperada (HTTP $http_code)"
        return 0
    fi
}

################################################################################
# Envía el estado final del proceso al sistema de callbacks
#
# Actualiza el registro de ejecución con el estado final y el resultado
# de la ejecución. Esto permite al sistema de NullPlatform saber si el
# proceso completó exitosamente o falló.
#
# Argumentos:
#   $1 - Estado del proceso (success, failed) - default: success
#   $2 - Estado de ejecución (success, failed) - default: success
#
# Variables requeridas:
#   - NOTIFICATION_CALLBACK_URL: URL del endpoint de callbacks
#   - NP_TOKEN: Token de autenticación de NullPlatform
#
# Retorna:
#   0 si el estado se envió exitosamente
#   1 si hubo algún error
################################################################################
send_final_status() {
    local status="${1:-success}"
    local execution_status="${2:-success}"
    
    # Validar variables requeridas
    if ! validate_required_vars "NOTIFICATION_CALLBACK_URL" "NP_TOKEN"; then
        log_error "Variables de notificación no están configuradas"
        return 1
    fi
    
    local response http_code
    
    log_info "Enviando estado final: status=$status, execution_status=$execution_status"
    
    # Enviar actualización de estado
    response=$(curl -s -w "\n%{http_code}" -X PATCH \
        "$NOTIFICATION_CALLBACK_URL" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $NP_TOKEN" \
        -d "{\"status\": \"$status\", \"execution_status\": \"$execution_status\"}")
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo enviar el estado final"
        return 1
    fi
    
    # Extraer código HTTP de la respuesta
    http_code=$(echo "$response" | tail -n1)
    
    # Verificar código de respuesta
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_success "Estado final enviado exitosamente"
        return 0
    else
        log_warn "Estado final enviado pero respuesta inesperada (HTTP $http_code)"
        return 0
    fi
}

################################################################################
# Envía múltiples notificaciones en secuencia
#
# Útil para enviar varias notificaciones de una vez sin repetir lógica.
#
# Argumentos:
#   Pares de nivel-mensaje: nivel1 mensaje1 nivel2 mensaje2 ...
#
# Ejemplo:
#   send_multiple_notifications \
#       "info" "Primera notificación" \
#       "warn" "Segunda notificación"
#
# Retorna:
#   0 si todas las notificaciones se enviaron
#   1 si alguna falló
################################################################################
send_multiple_notifications() {
    local all_success=0
    
    while [ $# -ge 2 ]; do
        local level="$1"
        local message="$2"
        shift 2
        
        if ! send_notification "$level" "$message"; then
            all_success=1
        fi
    done
    
    return $all_success
}
