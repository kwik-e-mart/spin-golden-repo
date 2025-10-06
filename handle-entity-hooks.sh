#!/usr/bin/env bash
set -euo pipefail

WORKING_DIRECTORY="$(dirname "$(realpath "$0")")"
cd "$WORKING_DIRECTORY" || exit 1


echo "Starting handle agent entity hooks"

# Si no está definida como variable de entorno, usa el argumento
: "${NP_ACTION_CONTEXT:=${1:-}}"

# Validar que NP_ACTION_CONTEXT tenga valor
if [[ -z "$NP_ACTION_CONTEXT" ]]; then
    echo "❌ Error: NP_ACTION_CONTEXT no está definido (ni como variable de entorno ni como argumento)."
    exit 1
fi

echo "📩 Notification received: $NP_ACTION_CONTEXT"

# Exportar variables desde el JSON
eval "$(echo "$NP_ACTION_CONTEXT" | jq -r '.notification | to_entries[] | "export NOTIFICATION_\(.key | ascii_upcase)=\"\(.value)\""')"

# Ejecutar hook según tipo de entidad
if [[ "$NOTIFICATION_ENTITY" == "application" ]]; then
    ./entity_hooks/golden_repo.sh
fi
