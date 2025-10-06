#!/bin/bash

################################################################################
# Script Principal - Golden Repository Automation
#
# Descripción:
#   Automatiza el proceso de actualización de metadata en repositorios GitHub
#   integrados con NullPlatform. Orquesta todas las operaciones necesarias
#   desde la autenticación hasta el commit de cambios.
#
# Requisitos:
#   - Variables de entorno: NP_API_KEY, NOTIFICATION_NRN, NOTIFICATION_CALLBACK_URL
#   - Herramientas: curl, jq, git, aws cli, openssl, np cli
#
# Autor: NullPlatform Agent
# Versión: 2.0
################################################################################

set -euo pipefail

# Obtener el directorio del script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Importar módulos
source "${SCRIPT_DIR}/lib/auth.sh"
source "${SCRIPT_DIR}/lib/github.sh"
source "${SCRIPT_DIR}/lib/repository.sh"
source "${SCRIPT_DIR}/lib/notification.sh"
source "${SCRIPT_DIR}/lib/utils.sh"

################################################################################
# Función de limpieza
# 
# Elimina directorios temporales y recursos creados durante la ejecución
################################################################################
cleanup() {
    if [ -n "${CLONE_DIR:-}" ] && [ -d "$CLONE_DIR" ]; then
        log_info "Limpiando directorio temporal: $CLONE_DIR"
        rm -rf "$CLONE_DIR"
    fi
}

################################################################################
# Manejador de errores
#
# Gestiona errores capturados, envía notificaciones y limpia recursos
#
# Argumentos:
#   $1 - Mensaje de error descriptivo
#   $2 - Código de salida (opcional, default: 1)
################################################################################
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"

    log_error "$error_message"

    # Intentar enviar notificación de error si las credenciales están disponibles
    if [ -n "${NOTIFICATION_CALLBACK_URL:-}" ] && [ -n "${NP_TOKEN:-}" ]; then
        send_notification "error" "Error en script: $error_message"
        send_final_status "failed" "failed"
    fi

    cleanup
    exit "$exit_code"
}

################################################################################
# Función Principal
#
# Orquesta el flujo completo del proceso:
#   1. Autenticación en NullPlatform
#   2. Extracción de información de la aplicación
#   3. Autenticación en GitHub
#   4. Clonación del repositorio
#   5. Actualización de metadata
#   6. Commit y push de cambios
#   7. Notificación de finalización
################################################################################
main() {
    log_info "=== Iniciando proceso de actualización de Golden Repository ==="

    # Configurar trap para limpieza automática al salir
    trap cleanup EXIT

    # === FASE 1: Autenticación y configuración ===
    log_info "Fase 1: Autenticación en NullPlatform"
    generate_np_token || handle_error "Fallo en generación de token de NullPlatform"

    log_info "Fase 2: Extracción de información de aplicación"
    extract_app_id || handle_error "Fallo al extraer ID de aplicación desde NOTIFICATION_NRN"
    
    load_app_variables || handle_error "Fallo al cargar variables de aplicación desde NullPlatform"

    # === FASE 2: Autenticación en GitHub ===
    log_info "Fase 3: Configuración de GitHub"
    extract_organization || handle_error "Fallo al extraer organización desde APP_REPOSITORY_URL"
    
    generate_github_token || handle_error "Fallo al generar token de instalación de GitHub"
    
    prepare_clone_urls || handle_error "Fallo al preparar URLs de clonación"

    # === FASE 3: Operaciones en el repositorio ===
    log_info "Fase 4: Operaciones en repositorio"
    clone_repository || handle_error "Fallo al clonar repositorio desde GitHub"
    
    configure_git_credentials || handle_error "Fallo al configurar credenciales de Git"
    
    update_metadata || handle_error "Fallo al actualizar archivo metadata.json"
    
    commit_and_push || handle_error "Fallo al hacer commit y push de cambios"

    # === FASE 4: Finalización ===
    log_info "Fase 5: Finalización"
    send_notification "info" "Proceso completado exitosamente"
    send_final_status "success" "success"

    log_success "=== Proceso completado exitosamente ==="
    cleanup
}

# Ejecutar función principal si el script es invocado directamente
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
