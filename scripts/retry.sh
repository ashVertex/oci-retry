#!/usr/bin/env bash
# Reintenta crear la VM Ampere A1 en Oracle Cloud hasta conseguirla y avisa por webhook.
# Repositorio PÚBLICO: aquí no hay ningún dato sensible; todo llega por variables de entorno
# (GitHub Secrets). No imprimir nunca la salida completa de OCI ni usar `set -x` / `curl -v`.
set -u

: "${OCI_TENANCY:?}" "${OCI_SUBNET:?}" "${OCI_IMAGE:?}" "${AD:?}"
: "${WEBHOOK_URL:?}" "${WEBHOOK_TOKEN:?}"

NAME="minecraft"
REGION="eu-madrid-1"
OCPUS=2
MEM=12
BOOT=100
MAX_SECONDS=20000

RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-0}"

# Envía por webhook el JSON recibido como argumento (no por stdin: curl no puede reenviar un pipe al
# reintentar). Nunca se imprime la respuesta ni el error de curl (podrían revelar el dominio):
# solo el código HTTP. 5xx/408/429 los reintenta curl.
notify() {
  local code rc
  code=$(curl -sS --fail --max-time 20 --retry 3 --retry-delay 5 \
    -o /dev/null -w '%{http_code}' \
    -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $WEBHOOK_TOKEN" \
    --data "$1" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "Notificación enviada."
    return 0
  fi
  echo "Aviso: la notificación falló (HTTP ${code:-000})."
  return 1
}

# Un solo punto de salida tras conseguir la máquina: nunca se vuelve a lanzar otra instancia.
finish() {
  # Desactiva el workflow (necesita permiso actions: write); si falla no importa, la comprobación
  # inicial de «minecraft» ya evita duplicados.
  if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
    gh workflow disable "${GITHUB_WORKFLOW:-oci-retry}" >/dev/null 2>&1 && echo "Workflow desactivado."
  fi
  exit 1   # a propósito: marca la ejecución como fallida (señal visible en GitHub)
}

# 1) ¿Ya existe la instancia? Entonces no hay nada que hacer.
if oci compute instance list --compartment-id "$OCI_TENANCY" --display-name "$NAME" --all 2>/dev/null \
  | grep -qE '"lifecycle-state": "(PROVISIONING|RUNNING|STARTING|STOPPED|STOPPING)"'; then
  echo "Ya existe la instancia, no hay nada que hacer."
  exit 0
fi

# 2) Bucle de reintentos.
while [ "$SECONDS" -lt "$MAX_SECONDS" ]; do
  OUT=$(oci compute instance launch \
    --compartment-id "$OCI_TENANCY" \
    --availability-domain "$AD" \
    --shape VM.Standard.A1.Flex \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM}" \
    --image-id "$OCI_IMAGE" \
    --subnet-id "$OCI_SUBNET" \
    --assign-public-ip true \
    --display-name "$NAME" \
    --boot-volume-size-in-gbs "$BOOT" \
    --ssh-authorized-keys-file "$HOME/key.pub" 2>/tmp/oci_err.txt)

  INSTANCE_ID=$(printf '%s' "$OUT" | jq -r '.data.id // empty' 2>/dev/null)

  if [[ "$INSTANCE_ID" == ocid1.instance.* ]]; then
    echo "INSTANCIA CREADA"
    echo "::add-mask::$INSTANCE_ID"

    PAYLOAD=$(jq -nc --arg id "$INSTANCE_ID" --arg run "$RUN_URL" --arg name "$NAME" --arg region "$REGION" \
      --argjson ocpus "$OCPUS" --argjson mem "$MEM" \
      '{event:"oci_instance_created",instance_id:$id,instance_name:$name,region:$region,ocpus:$ocpus,memory_gb:$mem,run_url:$run}')
    notify "$PAYLOAD"

    # 3) Segundo aviso (opcional): esperar a RUNNING y enviar la IP pública.
    #    Nunca se imprime la IP: los logs de este repo son públicos.
    for _ in $(seq 1 30); do
      STATE=$(oci compute instance get --instance-id "$INSTANCE_ID" 2>/dev/null | jq -r '.data."lifecycle-state" // empty')
      [ "$STATE" = "RUNNING" ] && break
      sleep 20
    done
    if [ "${STATE:-}" = "RUNNING" ]; then
      IP=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" 2>/dev/null | jq -r '.data[0]."public-ip" // empty')
      if [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "::add-mask::$IP"
        PAYLOAD=$(jq -nc --arg id "$INSTANCE_ID" --arg name "$NAME" --arg ip "$IP" \
          '{event:"oci_instance_running",instance_id:$id,instance_name:$name,public_ip:$ip}')
        notify "$PAYLOAD"
      else
        echo "No se pudo leer la IP pública; no se envía el segundo aviso."
      fi
    else
      echo "La instancia no llegó a RUNNING en el tiempo previsto (se avisó de la creación)."
    fi
    finish
  fi

  # Fallo: mostrar un motivo corto, sin OCIDs ni huellas (el log es público).
  MSG=$( { printf '%s
' "$OUT"; cat /tmp/oci_err.txt; } 2>/dev/null | grep -v '^[[:space:]]*$' | head -6     | sed -E 's/ocid1\.[A-Za-z0-9._-]+/<ocid>/g; s/([0-9a-fA-F]{2}:){7,}[0-9a-fA-F]{2}/<fp>/g' | cut -c1-200 | tr '
' ' ')
  echo "$(date +%H:%M:%S) ${MSG:-sin mensaje}"
  sleep $((120 + RANDOM % 60))
done

echo "Fin del tiempo de esta ejecución; la siguiente programada continuará."
