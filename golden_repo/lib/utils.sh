#!/bin/bash

################################################################################
# Módulo de Utilidades
#
# Proporciona funciones de utilidad general para logging, validación
# y operaciones comunes utilizadas en todo el proyecto
################################################################################

################################################################################
# Funciones de Logging
################################################################################

# Imprime mensaje informativo con timestamp
log_info() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $message"
}

# Imprime mensaje de éxito con timestamp
log_success() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [SUCCESS] ✓ $message"
}

# Imprime mensaje de advertencia con timestamp
log_warn() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] ⚠ $message" >&2
}

# Imprime mensaje de error con timestamp
log_error() {
    local message="$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] ✗ $message" >&2
}

################################################################################
# Funciones de Validación
################################################################################

# Valida que una variable de entorno esté definida y no vacía
# Argumentos:
#   $1 - Nombre de la variable
# Retorna:
#   0 si la variable está definida y no vacía
#   1 si la variable no está definida o está vacía
validate_env_var() {
    local var_name="$1"
    local var_value="${!var_name:-}"
    
    if [ -z "$var_value" ]; then
        log_error "Variable de entorno requerida no definida: $var_name"
        return 1
    fi
    
    return 0
}

# Valida que múltiples variables de entorno estén definidas
# Argumentos:
#   $@ - Lista de nombres de variables a validar
validate_required_vars() {
    local all_valid=0
    
    for var_name in "$@"; do
        if ! validate_env_var "$var_name"; then
            all_valid=1
        fi
    done
    
    return $all_valid
}

################################################################################
# Funciones de Manejo de Archivos
################################################################################

# Crea un archivo temporal seguro
# Retorna:
#   Ruta del archivo temporal creado
create_temp_file() {
    local prefix="${1:-tempfile}"
    local temp_file
    
    temp_file=$(mktemp "${prefix}_XXXXXX")
    
    if [ $? -ne 0 ]; then
        log_error "No se pudo crear archivo temporal"
        return 1
    fi
    
    echo "$temp_file"
    return 0
}

################################################################################
# Funciones de Procesamiento de Datos
################################################################################

# Extrae un valor de un JSON usando jq
# Argumentos:
#   $1 - JSON string
#   $2 - Query de jq
# Retorna:
#   Valor extraído o cadena vacía si falla
extract_json_value() {
    local json="$1"
    local query="$2"
    local value
    
    value=$(echo "$json" | jq -r "$query" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ "$value" = "null" ] || [ -z "$value" ]; then
        return 1
    fi
    
    echo "$value"
    return 0
}

# Obtiene timestamp en formato ISO 8601
get_iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Obtiene timestamp en formato ISO 8601 con segundos
get_iso_timestamp_seconds() {
    date -Iseconds
}

################################################################################
# Funciones de Gestión de Comandos
################################################################################

# Ejecuta un comando y captura su salida y código de retorno
# Argumentos:
#   $@ - Comando a ejecutar
# Retorna:
#   Código de retorno del comando
execute_command() {
    local output
    local exit_code
    
    output=$("$@" 2>&1)
    exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_error "Comando falló: $*"
        log_error "Salida: $output"
    fi
    
    return $exit_code
}

# Verifica que un comando esté disponible en el sistema
# Argumentos:
#   $1 - Nombre del comando
check_command_exists() {
    local cmd="$1"
    
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Comando requerido no encontrado: $cmd"
        return 1
    fi
    
    return 0
}

# Verifica múltiples comandos requeridos
check_required_commands() {
    local all_exist=0
    
    for cmd in "$@"; do
        if ! check_command_exists "$cmd"; then
            all_exist=1
        fi
    done
    
    return $all_exist
}
