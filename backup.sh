#!/usr/bin/env bash
# =============================================================================
# backup.sh
#
# Suite Integral de Backup de Proxmox VE a Disco USB Externo con Panel de Gestión.
#
# Funcionalidades Principales:
# 1. Menú interactivo completo con monitorización de estado y opciones modulares.
# 2. Diagnóstico previo de salud de almacenamiento (Kernel dmesg/journalctl y SMART).
# 3. Detección y selector interactivo de dispositivos USB externos con guardado de UUID.
# 4. Gestor de copias históricas en USB: listado con fechas, tamaños, días y borrado.
# 5. Gestor de discos y passthrough de VMs: activación/desactivación de backup=0.
# 6. Calculadora de espacio exacto requerido vs espacio disponible en el USB.
# 7. Notificaciones duales: Telegram (bot/chat) y Email (vzdump --mailto).
# 8. Gestor de logs: log local en la carpeta del script y log de sesión en USB.
# 9. Ejecución en Primer Plano o en Segundo Plano (background con seguimiento).
# 10. Compatibilidad 100% CLI para automatización y tareas programadas (cron).
# =============================================================================

set -Eeuo pipefail
umask 077

# PATH completo: desde cron solo existe /usr/bin:/bin y no se encontrarían qm, pct, vzdump, blkid...
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# Rutas y Variables Globales
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/backup.conf}"
HOST_LOG_FILE="${HOST_LOG_FILE:-$SCRIPT_DIR/backup.log}"
LOCK_FILE="${LOCK_FILE:-$SCRIPT_DIR/backup.lock}"
CRON_LOG_FILE="${CRON_LOG_FILE:-$SCRIPT_DIR/backup-cron.log}"  # Salida completa de las ejecuciones desde cron
CRON_LOG_MAX_BYTES=$((5 * 1024 * 1024))                         # Al superarlo se conservan solo las últimas líneas

USB_UUID=""
MOUNTPOINT="/media/backup"
BACKUP_ROOT="dump"
MIN_FREE_GB=20
KEEP_LAST=3

# Rendimiento y exclusiones
ZSTD_THREADS=0       # 0 = automático de vzdump, >0 = número de hilos CPU
BWLIMIT=70000        # Límite en KB/s (70000 = 70 MB/s, recomendado para USB mecánico para prevenir error E/S err -5)
BLACKLIST_VMS=""     # Lista de IDs separados por comas que se omiten siempre (ej: 105,106)

# Notificaciones
TELEGRAM_ENABLED=0
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
EMAIL_ENABLED=1
EMAIL_NOTIFICATION_TYPE="failure" # failure | always
NOTIFICATION_TARGET=""            # Destino nativo de Proxmox VE (se autodetecta o lee de backup.conf)
EMAIL_TO=""                       # Destinatario de los avisos propios del script (vacío = root → reenvío de Proxmox)

# Variables de ejecución
RUN_DIR=""
LOG_FILE=""
MOUNTED_BY_SCRIPT=0
FAILED=0
START_TIME=0
CONFIG_LOADED=0
ALERT_SENT=0
MENU_MODE=0
STOP_RC=0

# Estado compartido entre las fases del motor (execute_backup_engine); se reinicia en cada ejecución
ENGINE_LOCK_OK=0          # 1 = bloqueo (fd 200) obtenido
ENGINE_FINISHED=0         # 1 = el motor terminó por engine_finish (trap EXIT pasa a cleanup_mount)
ENGINE_FREE_GB=0          # Espacio libre en el USB al empezar (GiB)
ENGINE_EST_GB=0           # Estimación sin comprimir de lo seleccionado (GiB)
ENGINE_SELECTED=()        # IDs de VMs/LXCs a respaldar
ENGINE_DO_HOST=1          # 1 = respaldar también la configuración del host
ENGINE_STAMP=""           # Marca de tiempo de la sesión (nombres de log y tar del host)
ENGINE_NEW_ARCHIVES=()    # Archivos creados en esta sesión (para la verificación de integridad)
ENGINE_SUMMARY_REPORT=()  # Líneas del resumen final / notificación
ENGINE_VERIFY_FAILED=0    # 1 = alguna copia nueva no superó la verificación (se omite la retención)
ENGINE_PERF_OPTS=()       # Opciones de rendimiento de vzdump (--zstd / --bwlimit)
ENGINE_NOTIF_TARGET_OK=0  # 1 = vzdump admite --notification-target
ENGINE_TOTAL_SZ=""        # Tamaño total de la carpeta de copias al terminar
ENGINE_FINAL_FREE_GB=0    # Espacio libre en el USB al terminar (GiB)
ENGINE_TOTAL_ELAPSED=0    # Duración total de la sesión (s)

# Opciones CLI
CLI_ALL=0
CLI_YES=0
CLI_HOST_ONLY=0
CLI_SELECTED_GUESTS=""
CLI_INCLUDE_HOST=-1
CLI_DRY_RUN=0
CLI_BACKGROUND=0
CLI_STOP=0

# Colores de interfaz ANSI (Bash C-strings)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'

# Manejo limpio de Ctrl + C (SIGINT)
manejar_interrupcion() {
    echo -e "\n${YELLOW}⚠️ Ejecución interrumpida por el usuario (Ctrl + C). Saliendo...${NC}"
    exit 130
}
trap manejar_interrupcion INT

# ─────────────────────────────────────────────────────────────────────────────
# Funciones de Interfaz Visual (TUI Helpers)
# ─────────────────────────────────────────────────────────────────────────────
ui_hr() {
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────────${NC}"
}

ui_header() {
    local title="$1"
    clear 2>/dev/null || true
    echo -e "${CYAN}╭────────────────────────────────────────────────────────────────────────────╮${NC}"
    printf "${CYAN}│${NC} ${BOLD}%-74s${NC} ${CYAN}│${NC}\n" "$title"
    echo -e "${CYAN}╰────────────────────────────────────────────────────────────────────────────╯${NC}"
}

pause_prompt() {
    local msg="${1:-Presiona [Enter] para continuar...}"
    echo
    read -rp "$msg" _
}

ui_progress_bar() {
    local pct="${1:-0}"
    local width="${2:-16}"
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local color="$GREEN"
    (( pct >= 75 )) && color="$YELLOW"
    (( pct >= 90 )) && color="$RED"

    local bar_f="" bar_e=""
    for ((i=0; i<filled; i++)); do bar_f+="█"; done
    for ((i=0; i<empty; i++)); do bar_e+="░"; done
    printf "${color}[%s${GRAY}%s${color}] %d%%${NC}" "$bar_f" "$bar_e" "$pct"
}

# ─────────────────────────────────────────────────────────────────────────────
# Funciones de Logging y Ayuda
# ─────────────────────────────────────────────────────────────────────────────
log() {
    local raw_msg
    raw_msg="[$(date '+%F %T')] $*"
    # Salida por pantalla con colores interpretados
    printf '%b\n' "$raw_msg"
    # Log local persistente en la carpeta del script (sin códigos ANSI)
    if [[ -n "$HOST_LOG_FILE" ]]; then
        printf '%b\n' "$raw_msg" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$HOST_LOG_FILE" 2>/dev/null || true
    fi
    # Log específico de la sesión en el USB
    if [[ -n "$LOG_FILE" ]] && mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        printf '%b\n' "$raw_msg" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_info() {
    log "${GREEN}INFO:${NC} $*"
}

log_warn() {
    log "${YELLOW}ADVERTENCIA:${NC} $*"
}

log_err() {
    log "${RED}ERROR:${NC} $*"
}

abort() {
    log_err "$*"
    send_notifications_alert "❌ <b>Error Crítico en Backup Proxmox VE</b>%0A%0A• <b>Host:</b> $(html_escape "$(hostname)")%0A• <b>Motivo:</b> $(html_escape "$*")"
    ALERT_SENT=1
    exit 1
}

format_seconds() {
    local t=$1
    printf "%02dh:%02dm:%02ds" $((t/3600)) $(( (t%3600)/60 )) $((t%60))
}

ask_yes_no() {
    if [[ "$CLI_YES" -eq 1 ]]; then
        return 0
    fi
    local prompt="$1"
    local default="${2:-n}"
    local answer

    if [[ "$default" == "s" ]]; then
        read -r -p "$(echo -e "${prompt} [${BOLD}S${NC}/n]: ")" answer
        answer="${answer:-s}"
    else
        read -r -p "$(echo -e "${prompt} [s/${BOLD}N${NC}]: ")" answer
        answer="${answer:-n}"
    fi

    local clean_answer
    clean_answer="$(echo "$answer" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    [[ "$clean_answer" =~ ^(s|si|sí|y|yes)$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Carga y Guardado de Configuración Persistente (backup.conf en $SCRIPT_DIR)
# ─────────────────────────────────────────────────────────────────────────────
# Extrae el valor de una línea KEY=valor: respeta comillas (incluido '#' dentro de ellas)
# y elimina los comentarios en línea ("valor   # comentario") de los valores sin comillas.
# Entre comillas dobles se interpretan los escapes \\ \" \$ y \` igual que bash (los que escribe save_config).
parse_conf_value() {
    local v="$1"
    v="${v%$'\r'}"
    v="${v#"${v%%[![:space:]]*}"}"
    if [[ "$v" == \"* ]]; then
        local out="" c i
        v="${v#\"}"
        for (( i = 0; i < ${#v}; i++ )); do
            c="${v:i:1}"
            if [[ "$c" == '"' ]]; then
                break
            elif [[ "$c" == '\' && "${v:i+1:1}" == [\\\"\$\`] ]]; then
                out+="${v:i+1:1}"
                i=$(( i + 1 ))
            else
                out+="$c"
            fi
        done
        v="$out"
    elif [[ "$v" == \'* ]]; then
        v="${v#\'}"
        v="${v%%\'*}"
    else
        v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//')"
        v="${v%"${v##*[![:space:]]}"}"
    fi
    printf '%s' "$v"
}

# Valida los ajustes numéricos/enumerados (de backup.conf o de la CLI); si no son válidos, usa el valor por defecto
validate_settings() {
    local var def
    for var in KEEP_LAST:3 MIN_FREE_GB:20 ZSTD_THREADS:0 BWLIMIT:70000 EMAIL_ENABLED:1 TELEGRAM_ENABLED:0; do
        def="${var#*:}"
        var="${var%%:*}"
        if [[ ! "${!var}" =~ ^[0-9]+$ ]]; then
            log_warn "Valor no válido para $var ('${!var}'). Se usará el valor por defecto: $def"
            printf -v "$var" '%s' "$def"
        fi
    done
    if [[ "$EMAIL_NOTIFICATION_TYPE" != "failure" && "$EMAIL_NOTIFICATION_TYPE" != "always" ]]; then
        log_warn "Valor no válido para EMAIL_NOTIFICATION_TYPE ('$EMAIL_NOTIFICATION_TYPE'). Se usará: failure"
        EMAIL_NOTIFICATION_TYPE="failure"
    fi
    if [[ -n "$BLACKLIST_VMS" && ! "$BLACKLIST_VMS" =~ ^[0-9,[:space:]]+$ ]]; then
        log_warn "Valor no válido para BLACKLIST_VMS ('$BLACKLIST_VMS'). Se ignorará la lista negra."
        BLACKLIST_VMS=""
    fi
    return 0
}

# Carga backup.conf una sola vez por ejecución (los overrides de CLI se aplican después y no se pisan).
# Usa 'load_config --force' para releer el fichero explícitamente.
load_config() {
    if [[ "$CONFIG_LOADED" -eq 1 && "${1:-}" != "--force" ]]; then
        return 0
    fi
    CONFIG_LOADED=1

    # Migración/compatibilidad automática si existía la configuración en otra ruta previa
    if [[ ! -f "$CONFIG_FILE" ]]; then
        if [[ -f /root/backup.conf && "$CONFIG_FILE" != "/root/backup.conf" ]]; then
            cp -a /root/backup.conf "$CONFIG_FILE" 2>/dev/null || true
        elif [[ -f /etc/proxmox-usb-backup.conf ]]; then
            cp -a /etc/proxmox-usb-backup.conf "$CONFIG_FILE" 2>/dev/null || true
        fi
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        while IFS='=' read -r key val || [[ -n "$key" ]]; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            key="$(echo "$key" | tr -d ' ')"
            val="$(parse_conf_value "$val")"
            case "$key" in
                USB_UUID) USB_UUID="$val" ;;
                MOUNTPOINT) MOUNTPOINT="$val" ;;
                KEEP_LAST) KEEP_LAST="$val" ;;
                MIN_FREE_GB) MIN_FREE_GB="$val" ;;
                ZSTD_THREADS) ZSTD_THREADS="$val" ;;
                BWLIMIT) BWLIMIT="$val" ;;
                BLACKLIST_VMS) BLACKLIST_VMS="$val" ;;
                EMAIL_ENABLED) EMAIL_ENABLED="$val" ;;
                EMAIL_NOTIFICATION_TYPE) EMAIL_NOTIFICATION_TYPE="$val" ;;
                NOTIFICATION_TARGET) NOTIFICATION_TARGET="$val" ;;
                EMAIL_TO) EMAIL_TO="$val" ;;
                TELEGRAM_ENABLED) TELEGRAM_ENABLED="$val" ;;
                TELEGRAM_BOT_TOKEN) TELEGRAM_BOT_TOKEN="$val" ;;
                TELEGRAM_CHAT_ID) TELEGRAM_CHAT_ID="$val" ;;
            esac
        done < "$CONFIG_FILE"
    fi

    # Auto-detección inteligente: si Proxmox tiene configurado el storage 'backup', usar su ruta
    if [[ -f /etc/pve/storage.cfg ]]; then
        local pve_dir
        pve_dir="$(awk '/^[a-z]+:[[:space:]]*backup[[:space:]]*$/ {flag=1; next} /^[a-z]+:/ {flag=0} flag && /^[[:space:]]*path[[:space:]]+/ {print $2; exit}' /etc/pve/storage.cfg 2>/dev/null || true)"
        [[ -n "$pve_dir" ]] && MOUNTPOINT="$pve_dir"
    fi

    # Auto-detección inteligente de destino de notificación de Proxmox si no se ha guardado uno
    if [[ -z "$NOTIFICATION_TARGET" && -f /etc/pve/notifications.cfg ]]; then
        local found_target
        found_target="$(grep -E '^(smtp|sendmail):' /etc/pve/notifications.cfg 2>/dev/null | awk '{print $2}' | grep -iE 'gmail|alerta' | head -n1 || true)"
        [[ -z "$found_target" ]] && found_target="$(grep -E '^(smtp|sendmail):' /etc/pve/notifications.cfg 2>/dev/null | awk '{print $2}' | head -n1 || true)"
        [[ -n "$found_target" ]] && NOTIFICATION_TARGET="$found_target"
    fi

    validate_settings
}

# Entrecomilla un valor para backup.conf: comillas dobles escapando \\ " $ y ` (sintaxis de bash), de modo que
# parse_conf_value (y un 'source' del fichero) lo relean exactamente igual
conf_quote() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    v="${v//\`/\\\`}"
    printf '"%s"' "$v"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    cat <<EOF > "$CONFIG_FILE"
# =============================================================================
# Configuración persistente de backup.sh (Proxmox VE USB Backup)
# =============================================================================
USB_UUID=$(conf_quote "$USB_UUID")
MOUNTPOINT=$(conf_quote "$MOUNTPOINT")
KEEP_LAST=$KEEP_LAST
MIN_FREE_GB=$MIN_FREE_GB

# Rendimiento y exclusiones
ZSTD_THREADS=$ZSTD_THREADS
BWLIMIT=$BWLIMIT
BLACKLIST_VMS=$(conf_quote "$BLACKLIST_VMS")

# Notificaciones Telegram
TELEGRAM_ENABLED=$TELEGRAM_ENABLED
TELEGRAM_BOT_TOKEN=$(conf_quote "$TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID=$(conf_quote "$TELEGRAM_CHAT_ID")

# Notificaciones Proxmox VE
EMAIL_ENABLED=$EMAIL_ENABLED
EMAIL_NOTIFICATION_TYPE=$(conf_quote "$EMAIL_NOTIFICATION_TYPE")
NOTIFICATION_TARGET=$(conf_quote "$NOTIFICATION_TARGET")
# Destinatario de los avisos del propio script (fallos de montaje, espacio, bloqueo, verificación...).
# Vacío = root: Proxmox lo reenvía al email de root@pam (proxmox-mail-forward)
EMAIL_TO=$(conf_quote "$EMAIL_TO")
EOF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Módulo de Notificaciones (Telegram y Email)
# ─────────────────────────────────────────────────────────────────────────────
# Escapa &, < y > para insertar texto dinámico en mensajes con parse_mode=HTML
html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

send_telegram_message() {
    local text="$1"
    if [[ "$TELEGRAM_ENABLED" -ne 1 || -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        return 0
    fi
    # Los mensajes usan %0A como salto de línea; se convierten a saltos reales porque --data-urlencode codifica todo
    text="${text//%0A/$'\n'}"
    # El token se pasa a curl por stdin (-K -) para que no aparezca en la línea de comandos (ps)
    local curl_out curl_rc=0
    curl_out="$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
        curl -sS -f -m 10 -K - \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "text=${text}" 2>&1 >/dev/null)" || curl_rc=$?
    if [[ "$curl_rc" -ne 0 ]]; then
        log_warn "No se pudo enviar la notificación de Telegram (curl código $curl_rc): ${curl_out//"$TELEGRAM_BOT_TOKEN"/[token]}"
    fi
    return 0
}

# Convierte un mensaje con formato de Telegram (HTML y %0A) a texto plano para el email
html_to_text() {
    local text="${1//%0A/$'\n'}"
    printf '%s' "$text" | sed -e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g'
}

# Envía un email con los avisos propios del script (vzdump ya envía el suyo por cada VM/LXC).
# Usa el MTA del nodo (sendmail de postfix en Proxmox VE, o 'mail' como alternativa): el correo a root
# lo reenvía Proxmox al email de root@pam. Nunca hace fallar al script: si no puede enviar, lo registra.
send_email_alert() {
    local text="$1"
    [[ "$EMAIL_ENABLED" -eq 1 ]] || return 0
    local to="${EMAIL_TO:-root}"
    local body subject first_line
    body="$(html_to_text "$text")"
    first_line="$(printf '%s\n' "$body" | sed -n '/[^[:space:]]/{p;q}')"
    subject="[backup-proxmox] $(hostname): ${first_line:-Aviso}"

    local rc=0 out=""
    if command -v sendmail >/dev/null 2>&1; then
        # Asunto en UTF-8 codificado (RFC 2047) para que los emojis y acentos lleguen bien
        local enc_subject
        enc_subject="=?UTF-8?B?$(printf '%s' "$subject" | base64 -w0)?="
        out="$(printf 'To: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n' \
            "$to" "$enc_subject" "$body" | timeout 30 sendmail -i -- "$to" 2>&1)" || rc=$?
    elif command -v mail >/dev/null 2>&1; then
        out="$(printf '%s\n' "$body" | timeout 30 mail -s "$subject" -- "$to" 2>&1)" || rc=$?
    else
        log_warn "No se pudo enviar el aviso por email: no hay 'sendmail' ni 'mail' en el sistema."
        return 0
    fi
    if [[ "$rc" -ne 0 ]]; then
        log_warn "No se pudo enviar el aviso por email a $to (código $rc): $out"
    fi
    return 0
}

# Avisos del propio script (fallo de montaje, espacio, bloqueo, interrupción, verificación...): Telegram + email
send_notifications_alert() {
    local text="$1"
    send_telegram_message "$text"
    send_email_alert "$text"
}

# ─────────────────────────────────────────────────────────────────────────────
# Detección y Descubrimiento Dinámico de VMs y Contenedores
# ─────────────────────────────────────────────────────────────────────────────
declare -A GUEST_TYPES
declare -A GUEST_NAMES
declare -A GUEST_STATUS
ALL_GUEST_IDS=()

discover_guests() {
    GUEST_TYPES=()
    GUEST_NAMES=()
    GUEST_STATUS=()
    ALL_GUEST_IDS=()

    # Descubrir VMs (QEMU)
    while read -r vmid name status rest; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        ALL_GUEST_IDS+=("$vmid")
        GUEST_TYPES["$vmid"]="VM (QEMU)"
        GUEST_NAMES["$vmid"]="$name"
        GUEST_STATUS["$vmid"]="$status"
    done < <(qm list 2>/dev/null | tail -n +2 || true)

    # Descubrir Contenedores (LXC). La columna Lock puede ir vacía: el nombre es siempre el último campo
    while read -r vmid status rest; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        local name="${rest##* }"
        ALL_GUEST_IDS+=("$vmid")
        GUEST_TYPES["$vmid"]="LXC"
        GUEST_NAMES["$vmid"]="$name"
        GUEST_STATUS["$vmid"]="$status"
    done < <(pct list 2>/dev/null | tail -n +2 || true)
}

# ─────────────────────────────────────────────────────────────────────────────
# Cálculo de Tamaño de Discos (Excluyendo Passthrough /dev/ y backup=0)
# ─────────────────────────────────────────────────────────────────────────────
get_guest_config() {
    local gid="$1"
    local type="${2:-${GUEST_TYPES[$gid]:-}}"
    if [[ "$type" == *"VM"* ]]; then
        local conf_file="/etc/pve/qemu-server/${gid}.conf"
        if [[ -f "$conf_file" ]]; then
            cat "$conf_file" 2>/dev/null || true
        else
            qm config "$gid" 2>/dev/null || true
        fi
    elif [[ "$type" == "LXC" ]]; then
        local conf_file="/etc/pve/lxc/${gid}.conf"
        if [[ -f "$conf_file" ]]; then
            cat "$conf_file" 2>/dev/null || true
        else
            pct config "$gid" 2>/dev/null || true
        fi
    fi
}

# Sección principal de un .conf de Proxmox (antes del primer [snapshot] / [PENDING])
conf_main_section() {
    awk '/^\[/{exit} {print}' "$1" 2>/dev/null || true
}

# Discos passthrough (/dev/...) de la sección principal que aún no tienen backup=0
# (solo claves de disco: scsi/virtio/sata/ide en VMs y mpN en LXC; nunca serialN, devN, etc.)
conf_passthrough_without_backup0() {
    conf_main_section "$1" | grep -E '^(scsi|virtio|sata|ide|mp)[0-9]+:[[:space:]]*/dev/' | grep -v -E 'backup=(0|no)' || true
}

# Marca backup=0 en el disco <clave> SOLO en la sección principal (sustituye un backup=X previo o lo añade al final)
conf_disk_backup_off() {
    local conf_file="$1" key="$2"
    sed -i -E "0,/^\[/{/^${key}:/{s/,backup=[^,]*/,backup=0/;t;s/\$/,backup=0/}}" "$conf_file"
}

# Quita backup=0/no del disco <clave> SOLO en la sección principal, sin tocar el resto de opciones
conf_disk_backup_on() {
    local conf_file="$1" key="$2"
    sed -i -E "0,/^\[/{/^${key}:/s/,backup=(0|no)(,|\$)/\2/}" "$conf_file"
}

parse_disk_size_gb() {
    local val="$1"
    local disk_gb=0

    # 1. Intentar extraer tamaño explícito: size=123G / size=1953514584K / etc.
    if [[ "$val" =~ size=([0-9]+)([a-zA-Z]*) ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        unit="$(echo "$unit" | tr '[:lower:]' '[:upper:]')"
        case "$unit" in
            T|TB) disk_gb=$(( num * 1024 )) ;;
            G|GB) disk_gb=$(( num )) ;;
            M|MB) disk_gb=$(( (num + 1023) / 1024 )) ;;
            K|KB) disk_gb=$(( (num + 1048575) / 1024 / 1024 )) ;;
            "")
                if [[ "$num" -gt 1048576 ]]; then
                    disk_gb=$(( num / 1024 / 1024 ))
                elif [[ "$num" -gt 1024 ]]; then
                    disk_gb=$(( num / 1024 ))
                else
                    disk_gb=$(( num ))
                fi
                ;;
        esac
    fi

    # 2. Si no tiene size= y es un dispositivo passthrough /dev/..., obtener su tamaño físico
    if [[ "$disk_gb" -eq 0 && "$val" =~ (/dev/[^,[:space:]]+) ]]; then
        local dev_node="${BASH_REMATCH[1]}"
        if [[ -e "$dev_node" ]]; then
            local dev_bytes
            dev_bytes="$(lsblk -b -n -d -o SIZE "$dev_node" 2>/dev/null || blockdev --getsize64 "$dev_node" 2>/dev/null || echo 0)"
            if [[ "$dev_bytes" =~ ^[0-9]+$ && "$dev_bytes" -gt 0 ]]; then
                disk_gb=$(( dev_bytes / 1024 / 1024 / 1024 ))
            fi
        fi
    fi

    # Si sigue en 0, asumir al menos 1 GiB para no subestimar
    [[ "$disk_gb" -eq 0 ]] && disk_gb=1
    echo "$disk_gb"
}

estimate_guest_disk_gb() {
    local gid="$1"
    local type="${GUEST_TYPES[$gid]:-}"
    local total_gb=0
    local disk_regex="^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]+:"
    [[ "$type" == "LXC" ]] && disk_regex="^(rootfs|mp[0-9]+):"

    while read -r line; do
        [[ "$line" =~ ^\[.*\] ]] && break
        [[ "$line" =~ $disk_regex ]] || continue
        [[ "$line" =~ backup=(0|no) ]] && continue

        local val
        val="$(echo "$line" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
        local disk_gb
        disk_gb="$(parse_disk_size_gb "$val")"
        total_gb=$(( total_gb + disk_gb ))
    done < <(get_guest_config "$gid" "$type")

    [[ "$total_gb" -eq 0 ]] && total_gb=1
    echo "$total_gb"
}

# Escáner unificado de particiones externas / USB candidatas
scan_usb_candidates() {
    local parent_disks_with_parts
    parent_disks_with_parts="$(lsblk -n -o PKNAME 2>/dev/null | sort -u | grep -v '^$' || true)"

    while read -r p_line; do
        [[ -z "$p_line" ]] && continue
        local NAME="" SIZE="" FSTYPE="" LABEL="" UUID="" TRAN="" MODEL="" TYPE="" PKNAME="" DEV_MOUNTPOINT=""
        eval "${p_line//MOUNTPOINT=/DEV_MOUNTPOINT=}"
        [[ "$NAME" =~ ^loop ]] && continue
        [[ "$NAME" =~ ^pve-vm-- || "$NAME" =~ ^dm- || "$NAME" =~ ^zd[0-9]+ ]] && continue
        [[ -z "$UUID" ]] && continue
        [[ "$FSTYPE" == "swap" || "$FSTYPE" == "LVM2_member" || "$FSTYPE" == "crypto_LUKS" || "$FSTYPE" == "linux_raid_member" ]] && continue
        if [[ "$TYPE" == "disk" && " $parent_disks_with_parts " =~ [[:space:]]"$NAME"[[:space:]] ]]; then
            continue
        fi
        [[ "$DEV_MOUNTPOINT" == "/" || "$DEV_MOUNTPOINT" == "/boot" || "$DEV_MOUNTPOINT" == "/boot/efi" ]] && continue

        printf '%s\n' "$p_line"
    done < <(lsblk -P -o NAME,SIZE,FSTYPE,LABEL,UUID,TRAN,MODEL,TYPE,PKNAME,MOUNTPOINT 2>/dev/null || true)
}

# Limpieza de SHA256SUMS eliminando entradas de archivos ya purgados
sync_sha256sums() {
    local bdir="$1"
    local sha_file="$bdir/SHA256SUMS"
    [[ -f "$sha_file" ]] || return 0

    local tmp_sha
    tmp_sha="$(mktemp)"
    while read -r line; do
        local f_name
        f_name="$(echo "$line" | awk '{print $2}')"
        f_name="${f_name#./}"
        f_name="${f_name#\*}"
        if [[ -n "$f_name" && -f "$bdir/$f_name" ]]; then
            echo "$line" >> "$tmp_sha"
        fi
    done < "$sha_file"
    mv -f "$tmp_sha" "$sha_file" 2>/dev/null || rm -f "$tmp_sha"
}

# Purga unificada de copias antiguas según KEEP_LAST
prune_old_backups() {
    local backup_path="$1"
    local keep="${2:-$KEEP_LAST}"
    local dry_run="${3:-0}"
    [[ "$keep" -gt 0 && -d "$backup_path" ]] || return 0

    local all_gids=()
    mapfile -t all_gids < <(find "$backup_path" -maxdepth 1 -name "vzdump-*" 2>/dev/null | sed -E 's/.*vzdump-(qemu|lxc)-([0-9]+)-.*/\2/' | sort -u)
    local del_count=0

    for gid in "${all_gids[@]}"; do
        [[ -z "$gid" ]] && continue
        # Solo archivos de copia reales (.vma / .tar / .tgz con compresión opcional): los .notes, .log,
        # .protected y temporales (.dat, .tmp) de la misma copia no cuentan como copias adicionales.
        # Las copias protegidas (marca <archivo>.protected desde la GUI) ni se cuentan ni se borran nunca.
        local g_files=() cand
        while IFS= read -r cand; do
            [[ -z "$cand" ]] && continue
            if [[ -e "${cand}.protected" ]]; then
                [[ "$dry_run" -eq 1 ]] && echo -e "  ${CYAN}🔒 Protegida (no se purga):${NC} $(basename "$cand")"
                continue
            fi
            g_files+=("$cand")
        done < <(find "$backup_path" -maxdepth 1 -type f -regextype posix-extended \( \
                    -regex ".*/vzdump-qemu-${gid}-[^/]+\\.vma(\\.(zst|gz|lzo))?" -o \
                    -regex ".*/vzdump-lxc-${gid}-[^/]+\\.(tar|tgz)(\\.(zst|gz|lzo))?" \) 2>/dev/null | sort -r)
        local total_g=${#g_files[@]}
        if (( total_g > keep )); then
            for (( i=keep; i<total_g; i++ )); do
                local old_arch="${g_files[$i]}"
                local base_prefix="${old_arch%.vma*}"
                base_prefix="${base_prefix%.tar*}"
                base_prefix="${base_prefix%.tgz}"
                if [[ "$dry_run" -eq 1 ]]; then
                    echo -e "  ${YELLOW}[DRY-RUN] Purgaría:${NC} $(basename "$old_arch")"
                else
                    echo -e "  ${YELLOW}🗑️ Retención:${NC} Eliminando copia antigua $(basename "$old_arch")"
                    rm -f "$old_arch" "${base_prefix}"* 2>/dev/null || true
                    log_info "Retención: Eliminada copia antigua $(basename "$old_arch")"
                fi
                ((++del_count))
            done
        fi
    done

    # Ordenar por fecha de modificación (más reciente primero): por nombre, los antiguos 'pve-host-*'
    # quedarían por delante de los 'proxmox-host-*' nuevos y se borrarían las copias recientes
    mapfile -t host_files < <(find "$backup_path" -maxdepth 1 \( -name "proxmox-host-config-*.tar.gz" -o -name "pve-host-backup-*.tar.gz" \) -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    local total_h=${#host_files[@]}
    if (( total_h > keep )); then
        for (( i=keep; i<total_h; i++ )); do
            local old_h="${host_files[$i]}"
            if [[ "$dry_run" -eq 1 ]]; then
                echo -e "  ${YELLOW}[DRY-RUN] Purgaría:${NC} $(basename "$old_h")"
            else
                echo -e "  ${YELLOW}🗑️ Retención:${NC} Eliminando configuración del host antigua $(basename "$old_h")"
                rm -f "$old_h" 2>/dev/null || true
                log_info "Retención: Eliminada configuración antigua del host $(basename "$old_h")"
            fi
            ((++del_count))
        done
    fi

    [[ "$dry_run" -eq 0 ]] && sync_sha256sums "$backup_path"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Montaje y Desmontaje Seguro del USB
# ─────────────────────────────────────────────────────────────────────────────
mount_usb_device() {
    load_config
    if [[ -z "$USB_UUID" ]]; then
        return 1
    fi
    local dev_path="/dev/disk/by-uuid/$USB_UUID"

    if [[ ! -e "$dev_path" ]]; then
        return 1
    fi

    local real_device
    real_device="$(readlink -f "$dev_path")"
    local fstype
    fstype="$(blkid -s TYPE -o value "$real_device" || true)"

    mkdir -p "$MOUNTPOINT" || return 1

    # Si ya estaba montado, verificar si coincide
    local already_mounted=0
    if mountpoint -q "$MOUNTPOINT"; then
        local current_src
        current_src="$(readlink -f "$(findmnt -n -o SOURCE --target "$MOUNTPOINT" 2>/dev/null || true)")"
        if [[ "$current_src" == "$real_device" ]]; then
            already_mounted=1
        elif ! umount "$MOUNTPOINT" 2>/dev/null; then
            # Otro dispositivo ocupa el punto de montaje: no se fuerza (umount -l) para no romper su uso
            log_err "El punto de montaje $MOUNTPOINT está ocupado por otro dispositivo ($current_src) y no se pudo desmontar."
            return 1
        fi
    fi

    if [[ "$already_mounted" -eq 0 ]]; then
        if [[ "$fstype" == "exfat" ]]; then
            mount -t exfat -o rw,iocharset=utf8 "$dev_path" "$MOUNTPOINT" || return 1
        else
            mount -o rw "$dev_path" "$MOUNTPOINT" || return 1
        fi
        # Comprobación explícita: si no quedó montado, los backups irían al disco raíz
        mountpoint -q "$MOUNTPOINT" || return 1
        MOUNTED_BY_SCRIPT=1
    fi

    # Asegurar directorio dump nativo de Proxmox VE
    mkdir -p "$MOUNTPOINT/dump" || return 1
    # Sincronizar automáticamente copias previas de proxmox-backups a dump/ para que Proxmox las liste
    if [[ -d "$MOUNTPOINT/proxmox-backups" ]]; then
        find "$MOUNTPOINT/proxmox-backups" -type f \( -name "vzdump-*" -o -name "*host-backup*" -o -name "*host-config*" \) -exec mv -n {} "$MOUNTPOINT/dump/" \; 2>/dev/null || true
    fi

    # Verificación de escritura (un USB montado en solo lectura se considera un fallo)
    if ! touch "$MOUNTPOINT/.backup-write-test-$$" 2>/dev/null; then
        log_err "El disco USB montado en $MOUNTPOINT no admite escritura (¿solo lectura o sistema de archivos dañado?)."
        return 1
    fi
    rm -f "$MOUNTPOINT/.backup-write-test-$$"
    return 0
}

cleanup_mount() {
    local rc="${1:-$?}"
    trap - EXIT

    if [[ "$MOUNTED_BY_SCRIPT" -eq 1 ]]; then
        sync 2>/dev/null || true
        if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
            umount "$MOUNTPOINT" 2>/dev/null || umount -l "$MOUNTPOINT" 2>/dev/null || true
        fi
    fi
    exit "$rc"
}

# ¿Está montado en $MOUNTPOINT precisamente el USB configurado (USB_UUID)?
is_our_usb_mounted() {
    [[ -n "$USB_UUID" ]] && mountpoint -q "$MOUNTPOINT" 2>/dev/null || return 1
    local want cur
    want="$(readlink -f "/dev/disk/by-uuid/$USB_UUID" 2>/dev/null || true)"
    cur="$(readlink -f "$(findmnt -n -o SOURCE --target "$MOUNTPOINT" 2>/dev/null || true)" 2>/dev/null || true)"
    [[ -n "$want" && "$cur" == "$want" ]]
}

# Libera el bloqueo del motor: borra el PID guardado (evita que --stop actúe sobre un PID reutilizado) y cierra el fd 200
release_backup_lock() {
    if { true >&200; } 2>/dev/null; then
        : > "$LOCK_FILE" 2>/dev/null || true
        exec 200>&-
    fi
    return 0
}

# Comprueba que no haya una copia en curso antes de operaciones destructivas (desmontar, formatear, purgar, borrar)
ensure_no_backup_running() {
    if [[ -e "$LOCK_FILE" ]] && ! flock -n "$LOCK_FILE" true 2>/dev/null; then
        echo -e "${RED}ERROR: Hay una copia de seguridad en curso (bloqueo activo en $LOCK_FILE).${NC}"
        echo -e "Espera a que termine o detenla (opción 2 del menú o --stop) antes de ${1:-realizar esta operación}."
        return 1
    fi
    return 0
}

# Trap EXIT del motor: si la ejecución termina con error (set -e, señal, exit inesperado) envía alerta,
# libera el bloqueo y desmonta el USB solo si lo montó el script
engine_exit_handler() {
    local rc=$?
    trap - EXIT
    if [[ "$rc" -ne 0 && "$ALERT_SENT" -eq 0 ]]; then
        ALERT_SENT=1
        log_err "La copia de seguridad terminó de forma inesperada (código $rc)."
        send_notifications_alert "❌ <b>Backup Proxmox VE interrumpido</b>%0A%0A• <b>Host:</b> $(html_escape "$(hostname)")%0A• <b>Código de salida:</b> $rc%0A• <b>Revisa log:</b> <code>$(html_escape "$HOST_LOG_FILE")</code>"
    fi
    release_backup_lock
    cleanup_mount "$rc"
}

# Fin normal del motor: libera el bloqueo y deja como trap solo el desmontaje (sin alerta) para la salida del script
engine_finish() {
    ENGINE_FINISHED=1
    release_backup_lock
    trap cleanup_mount EXIT
}

# Prueba de integridad de un archivo comprimido según su extensión (0 = correcto o formato sin prueba disponible)
test_archive_file() {
    local f="$1" rc=0
    case "$f" in
        *.zst) zstd -t "$f" >/dev/null 2>&1 || rc=$? ;;
        *.tar.gz|*.tgz) tar -tzf "$f" >/dev/null 2>&1 || rc=$? ;;
        *.gz) gzip -t "$f" >/dev/null 2>&1 || rc=$? ;;
        *.lzo)
            if command -v lzop >/dev/null 2>&1; then
                lzop -t "$f" >/dev/null 2>&1 || rc=$?
            fi
            ;;
    esac
    return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# CONTROL DE PROCESOS EN SEGUNDO PLANO Y DESBLOQUEO DE PROXMOX
# ─────────────────────────────────────────────────────────────────────────────
# ¿El PID corresponde a una instancia de este script? (comprobación exacta de argv, no por subcadena)
is_backup_script_pid() {
    local pid="$1" arg
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
    while IFS= read -r -d '' arg; do
        case "${arg##*/}" in
            backup.sh|backup-proxmox-usb.sh) return 0 ;;
        esac
    done 2>/dev/null < "/proc/$pid/cmdline"
    return 1
}

# Lista recursiva de descendientes de un PID (vzdump, tar, zstd... lanzados por el backup)
get_descendant_pids() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null || true); do
        echo "$child"
        get_descendant_pids "$child"
    done
}

get_running_backup_pids() {
    local my_pid=$$
    local my_bashpid=$BASHPID
    local my_ppid=$PPID
    local roots=() pids=() p c

    [[ -f "$LOCK_FILE" ]] || return 0

    # 1. Procesos que mantienen abierto el fichero de bloqueo (la instancia activa y los hijos que heredan el fd)
    for p in $(fuser "$LOCK_FILE" 2>/dev/null || true); do
        roots+=("$p")
    done
    # 2. PID guardado en LOCK_FILE, solo si sigue siendo realmente una instancia de este script
    local saved_pid
    saved_pid="$(head -n 1 "$LOCK_FILE" 2>/dev/null || true)"
    if is_backup_script_pid "$saved_pid"; then
        roots+=("$saved_pid")
    fi

    # 3. Solo esos procesos y sus descendientes: nunca otros vzdump o procesos ajenos del host
    for p in "${roots[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        [[ "$p" == "$my_pid" || "$p" == "$my_bashpid" || "$p" == "$my_ppid" ]] && continue
        pids+=("$p")
        while read -r c; do
            [[ -n "$c" && "$c" != "$my_pid" && "$c" != "$my_bashpid" ]] && pids+=("$c")
        done < <(get_descendant_pids "$p")
    done

    if [[ ${#pids[@]} -gt 0 ]]; then
        printf "%s\n" "${pids[@]}" | sort -un | tr '\n' ' ' | sed 's/ $//'
    fi
}

get_active_backup_detail() {
    local pids_str="$1"
    [[ -z "$pids_str" ]] && return

    local first_pid
    first_pid="$(echo "$pids_str" | awk '{print $1}')"
    local etime="?"
    if kill -0 "$first_pid" 2>/dev/null; then
        etime="$(ps -p "$first_pid" -o etime= 2>/dev/null | tr -d ' ' || echo "?")"
    fi

    local current_task=""

    # 1. ¿Está vzdump ejecutándose activamente?
    local v_cmd="" v_pid v_args
    for v_pid in $pids_str; do
        v_args="$(ps -p "$v_pid" -o args= 2>/dev/null || true)"
        if [[ "$v_args" =~ (^|/|[[:space:]])vzdump([[:space:]]|$) ]]; then
            v_cmd="$v_args"
            break
        fi
    done

    if [[ -n "$v_cmd" ]]; then
        local vmid
        vmid="$(echo "$v_cmd" | grep -oE '(^|[[:space:]])[0-9]+([[:space:]]|$)' | tr -d ' ' | head -n 1 || true)"
        if [[ -n "$vmid" ]]; then
            local gname="ID $vmid"
            local qm_name pct_name
            qm_name="$(qm config "$vmid" 2>/dev/null | grep '^name:' | awk '{print $2}' || true)"
            pct_name="$(pct config "$vmid" 2>/dev/null | grep '^hostname:' | awk '{print $2}' || true)"
            if [[ -n "$qm_name" ]]; then
                gname="VM $vmid ($qm_name)"
            elif [[ -n "$pct_name" ]]; then
                gname="LXC $vmid ($pct_name)"
            fi
            current_task="Copiando $gname"
        else
            current_task="Ejecutando vzdump"
        fi
    fi

    # 2. ¿Está comprimiendo la configuración del Host Proxmox?
    if [[ -z "$current_task" ]]; then
        if pgrep -f "proxmox-host-config" >/dev/null 2>&1; then
            current_task="Comprimiendo configuración del Host Proxmox"
        fi
    fi

    # 3. ¿Está verificando integridad zstd o sha256?
    if [[ -z "$current_task" ]]; then
        if pgrep -f "zstd -t" >/dev/null 2>&1; then
            current_task="Verificando integridad (zstd -t)"
        elif pgrep -f "sha256sum" >/dev/null 2>&1; then
            current_task="Generando sumas SHA256"
        fi
    fi

    # 4. Consultar avance o última acción registrada en log
    local progress=""
    local chk_log="${HOST_LOG_FILE:-$SCRIPT_DIR/backup.log}"
    if [[ -f "$chk_log" ]]; then
        local st_line
        st_line="$(tail -n 30 "$chk_log" 2>/dev/null | grep -oE 'status:[[:space:]]*[0-9]+%' | tail -n 1 || true)"
        [[ -n "$st_line" ]] && progress=" (~${st_line#status: })"

        if [[ -z "$current_task" ]]; then
            local last_action
            last_action="$(tail -n 20 "$chk_log" 2>/dev/null | grep -E 'Respaldando|Iniciando vzdump|Configuración del host|Purgando|Integridad|vzdump completado' | tail -n 1 || true)"
            if [[ -n "$last_action" ]]; then
                current_task="$(echo "$last_action" | sed -r 's/\x1B\[[0-9;]*[mK]//g' | sed -E 's/^\[[0-9: -]+\][[:space:]]*//' | sed 's/^INFO: //' | cut -c 1-50)"
            fi
        fi
    fi

    [[ -z "$current_task" ]] && current_task="Procesando copia de seguridad"

    echo "$current_task$progress | Tiempo activo: $etime"
}

unlock_all_guests_safe() {
    echo -e "${CYAN}Comprobando bloqueos residuales en Proxmox (qm/pct unlock)...${NC}"
    # Si sigue activo algún vzdump (ajeno a este script, p. ej. un job de la GUI), sus 'lock: backup' son legítimos
    if pgrep -f 'vzdump' >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️ Hay otro proceso vzdump en ejecución (ajeno a este script): no se liberan bloqueos para no interferir.${NC}"
        return 0
    fi
    local unlocked=0
    # VMs
    while read -r vmid name status rest; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        if qm config "$vmid" 2>/dev/null | grep -q "^lock:[[:space:]]*backup"; then
            echo -e "  ${YELLOW}• Liberando bloqueo en VM $vmid ($name)...${NC}"
            qm unlock "$vmid" 2>/dev/null || true
            ((++unlocked))
        fi
    done < <(qm list 2>/dev/null | tail -n +2 || true)

    # LXCs (la columna Lock puede ir vacía: el nombre es el último campo)
    while read -r vmid status rest; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        local name="${rest##* }"
        if pct config "$vmid" 2>/dev/null | grep -q "^lock:[[:space:]]*backup"; then
            echo -e "  ${YELLOW}• Liberando bloqueo en LXC $vmid ($name)...${NC}"
            pct unlock "$vmid" 2>/dev/null || true
            ((++unlocked))
        fi
    done < <(pct list 2>/dev/null | tail -n +2 || true)

    if [[ "$unlocked" -gt 0 ]]; then
        echo -e "${GREEN}✓ Se han liberado $unlocked bloqueos residuales con éxito.${NC}"
        log_warn "Se liberaron $unlocked bloqueos residuales de Proxmox."
    else
        echo -e "${GRAY}No se encontraron bloqueos residuales huérfanos en VMs o LXCs.${NC}"
    fi
}

# ¿Se ejecuta --stop sin terminal (cron, nohup, tubería)? En ese caso no se pregunta ni se espera [Enter]
stop_is_unattended() {
    [[ "$MENU_MODE" -eq 0 && ! -t 0 ]]
}

# Confirmación de stop_running_backup: sin terminal y sin -y no se lee nada y se asume 'No' (opción segura)
stop_ask_yes_no() {
    if stop_is_unattended && [[ "$CLI_YES" -ne 1 ]]; then
        echo -e "$1 ${GRAY}→ No (sin terminal interactiva: usa -y para confirmar)${NC}"
        return 1
    fi
    ask_yes_no "$1" "$2"
}

# Pausa de stop_running_backup (se omite sin terminal)
stop_pause_prompt() {
    stop_is_unattended && return 0
    pause_prompt
}

# Detiene la copia en curso de este script (SIGTERM y, si hace falta, SIGKILL), libera locks residuales y
# desmonta el USB. STOP_RC=1 si había una copia en curso y no se detuvo por falta de confirmación sin terminal.
stop_running_backup() {
    STOP_RC=0
    ui_header "🛑 DETENER / CANCELAR PROCESO DE COPIA DE SEGURIDAD"

    local pids_str
    pids_str="$(get_running_backup_pids)"

    if [[ -z "$pids_str" ]]; then
        echo -e "\n${GREEN}✓ No hay ningún proceso de copia de seguridad ejecutándose en este momento.${NC}\n"
        if stop_ask_yes_no "¿Deseas verificar y liberar posibles bloqueos residuales de Proxmox (qm/pct unlock)?" "n"; then
            echo
            unlock_all_guests_safe
        fi
        stop_pause_prompt
        return 0
    fi

    local task_info
    task_info="$(get_active_backup_detail "$pids_str")"
    echo -e "\n${YELLOW}⚠️ Se ha detectado una copia de seguridad en ejecución:${NC}"
    echo -e "  • ${BOLD}Tarea actual:${NC} ${CYAN}$task_info${NC}"
    echo -e "  • ${BOLD}PIDs asociados:${NC} $pids_str\n"
    echo "Detalle de procesos del sistema:"
    for pid in $pids_str; do
        if kill -0 "$pid" 2>/dev/null; then
            local p_cmd p_user p_time
            p_cmd="$(ps -p "$pid" -o cmd= 2>/dev/null || echo "Desconocido")"
            p_user="$(ps -p "$pid" -o user= 2>/dev/null || echo "root")"
            p_time="$(ps -p "$pid" -o etime= 2>/dev/null || echo "?")"
            echo -e "  • [PID ${BOLD}$pid${NC}] (Usuario: $p_user, Tiempo activo: $p_time)"
            echo -e "    Comando: ${GRAY}$p_cmd${NC}"
        fi
    done

    echo
    echo -e "${RED}${BOLD}ADVERTENCIA: Detener la copia en curso interrumpirá el proceso actual.${NC}"
    echo -e "El script enviará la señal de parada, esperará a los subprocesos,"
    echo -e "liberará los bloqueos 'lock: backup' en las VMs/LXCs y sincronizará el disco USB."
    echo

    if ! stop_ask_yes_no "¿Confirmas que deseas DETENER y cancelar estos procesos de backup?" "n"; then
        echo -e "\nOperación cancelada. El proceso de copia continúa ejecutándose."
        stop_is_unattended && STOP_RC=1
        stop_pause_prompt
        return 0
    fi

    echo -e "\n${CYAN}1. Enviando señal de terminación ordenada (SIGTERM)...${NC}"
    for pid in $pids_str; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -15 "$pid" 2>/dev/null || true
        fi
    done

    # Esperar hasta 5 segundos a que finalicen limpiamente
    local waited=0
    while [[ $waited -lt 5 ]]; do
        local still_alive=0
        for pid in $pids_str; do
            if kill -0 "$pid" 2>/dev/null; then
                still_alive=1
                break
            fi
        done
        [[ $still_alive -eq 0 ]] && break
        sleep 1
        ((++waited))
    done

    # Si aún sobreviven, forzar con SIGKILL
    for pid in $pids_str; do
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${YELLOW}Forzando terminación de PID $pid (SIGKILL)...${NC}"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done

    # Vaciar el PID guardado en el bloqueo (no se borra el fichero para no romper flock)
    : > "$LOCK_FILE" 2>/dev/null || true

    # Liberar bloqueos residuales en Proxmox
    echo
    unlock_all_guests_safe

    # Sincronizar escrituras pendientes y desmontar USB de forma segura
    echo -e "\n${CYAN}2. Sincronizando escrituras pendientes a disco (sync)...${NC}"
    sync 2>/dev/null || true
    # Solo se desmonta si en $MOUNTPOINT está el USB configurado (nunca otro dispositivo)
    if is_our_usb_mounted; then
        echo -e "${CYAN}3. Desmontando almacenamiento USB de forma segura...${NC}"
        umount "$MOUNTPOINT" 2>/dev/null || umount -l "$MOUNTPOINT" 2>/dev/null || true
    fi

    log_warn "Copia de seguridad detenida manualmente por el usuario. PIDs afectados: $pids_str"

    echo -e "\n${GREEN}✓ Todos los procesos de backup han sido detenidos con éxito.${NC}"
    echo -e "${GREEN}✓ Bloqueos residuales de Proxmox revisados y liberados.${NC}"
    echo -e "${GREEN}✓ Almacenamiento USB sincronizado.${NC}"
    stop_pause_prompt
}

menu_disk_health() {
    ui_header "🔍 DIAGNÓSTICO: SALUD DE DISCOS Y REGISTROS DEL KERNEL"

    echo -e "\n${BOLD}1. Registros de Error en el Kernel (últimas 24h):${NC}"
    local kernel_errors
    kernel_errors="$(
        journalctl -k --since "24 hours ago" --no-pager 2>/dev/null |
        grep -Ei 'I/O error|READ FPDMA QUEUED|ata[0-9]+.*(error|failed)|Buffer I/O error|EXT4-fs error|BTRFS error' |
        tail -20 || true
    )"

    if [[ -n "$kernel_errors" ]]; then
        echo -e "${RED}⚠️ Se han detectado incidencias recientes de hardware en el log del kernel:${NC}"
        printf '%s\n' "$kernel_errors"
    else
        echo -e "  ${GREEN}✓ Sin registros de errores I/O ni fallos ATA en el kernel (24h).${NC}"
    fi

    echo -e "\n${BOLD}2. Estado de Salud SMART de Discos Físicos:${NC}"
    if command -v smartctl >/dev/null 2>&1; then
        while read -r dev rest; do
            [[ -b "$dev" ]] || continue
            local smart_status
            smart_status="$(smartctl -H "$dev" 2>/dev/null | grep -Ei 'overall-health|SMART Health Status' || echo "No disponible")"
            local temp
            temp="$(smartctl -A "$dev" 2>/dev/null | awk '/Temperature_Celsius|Airflow_Temperature/ {print $10"°C"}' | head -n1 || true)"
            echo -e "  • ${CYAN}$dev${NC} ($rest): ${GREEN}$smart_status${NC} ${temp:+[Temp: $temp]}"
        done < <(smartctl --scan 2>/dev/null || true)
    else
        echo -e "  ${YELLOW}smartctl no está instalado (instalar con: apt install smartmontools).${NC}"
    fi

    echo -e "\n${BOLD}3. Estado del Disco USB Configurado (${USB_UUID:-sin configurar}):${NC}"
    local dev_path="/dev/disk/by-uuid/$USB_UUID"
    if [[ -n "$USB_UUID" && -e "$dev_path" ]]; then
        local real_dev
        real_dev="$(readlink -f "$dev_path")"
        local fstype
        fstype="$(blkid -s TYPE -o value "$real_dev" || true)"
        echo -e "  • Dispositivo detectado: ${GREEN}$real_dev${NC} (Sistema de archivos: $fstype)"
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL,SERIAL "$real_dev" 2>/dev/null | sed 's/^/    /'
    else
        echo -e "  • ${RED}No conectado o no encontrado con UUID $USB_UUID.${NC}"
    fi

    pause_prompt "Presiona [Enter] para volver al menú principal..."
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. MENÚ: Seleccionar / Detectar Disco USB de Copias
# ─────────────────────────────────────────────────────────────────────────────
menu_select_usb() {
    ui_header "💽 SELECCIÓN Y DETECCIÓN DE DISCO USB DE COPIAS"
    echo -e "UUID configurado actualmente: ${GREEN}${BOLD}$USB_UUID${NC}\n"

    echo "Escaneando unidades de almacenamiento conectadas..."
    local candidates=()
    mapfile -t candidates < <(scan_usb_candidates)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo -e "${RED}No se encontraron particiones externas o USB con UUID válido.${NC}"
        pause_prompt
        return
    fi

    echo -e "${BOLD}Particiones detectadas en el sistema:${NC}\n"
    local idx=1
    declare -A MAP_UUID
    for cand in "${candidates[@]}"; do
        local NAME="" SIZE="" FSTYPE="" LABEL="" UUID="" TRAN="" MODEL="" TYPE="" PKNAME="" DEV_MOUNTPOINT=""
        eval "${cand//MOUNTPOINT=/DEV_MOUNTPOINT=}"

        local active_tag=""
        [[ "$UUID" == "$USB_UUID" ]] && active_tag="${GREEN} [ACTUAL]${NC}"
        local is_usb=""
        [[ "$TRAN" == "usb" ]] && is_usb="${CYAN}(USB)${NC} "
        [[ -n "$MODEL" ]] && is_usb+="${GRAY}[$MODEL]${NC} "
        local lbl_info=""
        [[ -n "$LABEL" ]] && lbl_info=" \"$LABEL\""

        echo -e "  ${YELLOW}$idx)${NC} /dev/$NAME ($SIZE) [$FSTYPE]$lbl_info $is_usb$active_tag"
        echo -e "      └─> UUID: ${BOLD}$UUID${NC}"
        MAP_UUID["$idx"]="$UUID"
        ((++idx))
    done

    echo -e "\n  ${YELLOW}m)${NC} Introducir UUID manualmente"
    echo -e "  ${YELLOW}v)${NC} Volver sin cambiar nada"
    ui_hr
    read -rp "👉 Elige una opción [1-$((idx-1))/m/v]: " choice

    local new_uuid=""
    case "$choice" in
        v|V) return ;;
        m|M)
            read -rp "Introduce el nuevo UUID: " manual_uuid
            new_uuid="$(echo "$manual_uuid" | tr -d ' ')"
            ;;
        *)
            if [[ -n "${MAP_UUID[$choice]:-}" ]]; then
                new_uuid="${MAP_UUID[$choice]}"
            fi
            ;;
    esac

    if [[ -n "$new_uuid" ]]; then
        USB_UUID="$new_uuid"
        save_config
        echo -e "${GREEN}✓ UUID actualizado con éxito a: $USB_UUID${NC}"
        if ! ensure_no_backup_running "cambiar el disco montado"; then
            pause_prompt
            return
        fi
        if ask_yes_no "¿Deseas montar este disco USB en $MOUNTPOINT ahora mismo?" "s"; then
            umount "$MOUNTPOINT" 2>/dev/null || true
            if mount_usb_device; then
                MOUNTED_BY_SCRIPT=0
                echo -e "${GREEN}✓ Disco montado correctamente en $MOUNTPOINT.${NC}"
            else
                echo -e "${RED}ERROR al montar el disco.${NC}"
            fi
        fi
        sleep 1.5
    fi
}

test_backup_integrity() {
    local target="$1"
    ui_header "🧪 VERIFICACIÓN DE INTEGRIDAD DE ARCHIVOS EN EL USB"

    # Soporte si se pasa un archivo individual (vía dump/)
    if [[ -f "$target" ]]; then
        local file_sha_failed=0
        local bdir
        bdir="$(dirname "$target")"
        local aname
        aname="$(basename "$target")"
        local asz
        asz="$(du -sh "$target" 2>/dev/null | awk '{print $1}')"
        echo -e "Archivo a verificar: ${BOLD}$aname${NC} (${CYAN}$asz${NC})\n"

        if [[ -f "$bdir/SHA256SUMS" ]] && grep -q "  $aname$" "$bdir/SHA256SUMS" 2>/dev/null; then
            echo -e "${CYAN}1. Comprobando suma criptográfica SHA-256...${NC}"
            local expected_hash real_hash
            expected_hash="$(grep "  $aname$" "$bdir/SHA256SUMS" | head -n1 | awk '{print $1}')"
            echo -n "  • Calculando hash SHA256 de $aname... "
            real_hash="$(sha256sum "$target" 2>/dev/null | awk '{print $1}')"
            if [[ "$expected_hash" == "$real_hash" ]]; then
                echo -e "${GREEN}CORRECTO [OK]${NC}"
            else
                echo -e "${RED}CORRUPTO [FALLÓ]${NC}"
                file_sha_failed=1
            fi
            echo
        fi

        echo -e "${CYAN}2. Comprobando descompresión de bloques de datos...${NC}"
        echo -n "  • Probando streaming de $aname... "
        local t_rc=0
        test_archive_file "$target" || t_rc=$?

        echo
        ui_hr
        if [[ "$t_rc" -eq 0 && "$file_sha_failed" -eq 0 ]]; then
            echo -e "${GREEN}${BOLD}✓ Resultado: El archivo está 100% íntegro y sin errores de lectura/descompresión.${NC}"
        elif [[ "$t_rc" -eq 0 ]]; then
            echo -e "${RED}${BOLD}❌ Resultado: La suma SHA-256 no coincide con la registrada. El archivo ha cambiado o está corrupto.${NC}"
        else
            echo -e "${RED}${BOLD}❌ Resultado: Error de integridad (Código: $t_rc). El archivo puede estar corrupto o incompleto.${NC}"
        fi
        return
    fi

    local bdir="$target"
    echo -e "Directorio de la copia: ${BOLD}$(basename "$bdir")${NC}\n"
    sync_sha256sums "$bdir"

    # 1. Comprobar si existe SHA256SUMS
    local sha_failed=0
    if [[ -f "$bdir/SHA256SUMS" ]]; then
        echo -e "${CYAN}1. Comprobando sumas SHA-256 registradas al momento del backup...${NC}"
        while read -r line; do
            local expected_hash f_name
            expected_hash="$(echo "$line" | awk '{print $1}')"
            f_name="$(echo "$line" | awk '{print $2}')"
            [[ -z "$f_name" ]] && continue
            f_name="${f_name#./}"
            f_name="${f_name#\*}"

            local target_f="$bdir/$f_name"
            if [[ ! -f "$target_f" ]]; then
                echo -e "  ❌ $f_name: ${RED}NO ENCONTRADO${NC}"
                sha_failed=1
                continue
            fi

            echo -n "  • Verificando hash SHA256 de $f_name... "
            local real_hash
            real_hash="$(sha256sum "$target_f" 2>/dev/null | awk '{print $1}')"
            if [[ "$expected_hash" == "$real_hash" ]]; then
                echo -e "${GREEN}CORRECTO [OK]${NC}"
            else
                echo -e "${RED}CORRUPTO [FALLÓ]${NC}"
                sha_failed=1
            fi
        done < "$bdir/SHA256SUMS"
        echo
    fi

    # 2. Comprobar compresión zstd y tar directamente
    echo -e "${CYAN}2. Comprobando descompresión de bloques (zstd -t y tar -tzf)...${NC}"
    local archives=()
    mapfile -t archives < <(find "$bdir" -maxdepth 1 -type f \( -name "*.zst" -o -name "*.gz" -o -name "*.tar*" \) ! -name "*.log" ! -name "SHA256SUMS" 2>/dev/null | sort -r || true)

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "No se encontraron archivos comprimidos en este directorio."
        if [[ "$sha_failed" -ne 0 ]]; then
            echo -e "${RED}${BOLD}❌ Resultado: Hay sumas SHA-256 que no coinciden o archivos registrados que faltan.${NC}"
        fi
        return
    fi

    local corrupted_count=0
    for arch in "${archives[@]}"; do
        local aname
        aname="$(basename "$arch")"
        echo -n "  • Probando integridad de $aname... "
        local t_rc=0
        test_archive_file "$arch" || t_rc=$?

        if [[ "$t_rc" -eq 0 ]]; then
            echo -e "${GREEN}${BOLD}✓ ÍNTEGRO (Sin errores de bloques)${NC}"
        else
            echo -e "${RED}${BOLD}❌ ERROR DE CORRUPCIÓN (Código: $t_rc)${NC}"
            ((++corrupted_count))
        fi
    done

    echo
    ui_hr
    if [[ "$corrupted_count" -eq 0 && "$sha_failed" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✓ Resultado: Todos los archivos de esta copia están 100% sanos e íntegros.${NC}"
    else
        [[ "$corrupted_count" -gt 0 ]] && echo -e "${RED}${BOLD}❌ Resultado: Se encontraron $corrupted_count archivo(s) corrupto(s) en esta copia.${NC}"
        [[ "$sha_failed" -ne 0 ]] && echo -e "${RED}${BOLD}❌ Resultado: Hay sumas SHA-256 que no coinciden o archivos registrados que faltan.${NC}"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. MENÚ: Gestionar Copias en USB (Tabla compacta, test y eliminación)
# ─────────────────────────────────────────────────────────────────────────────
menu_manage_backups() {
    while true; do
        ui_header "📦 GESTIÓN DE COPIAS DE SEGURIDAD EN EL USB"

        if ! mount_usb_device; then
            echo -e "${RED}ERROR: No se pudo montar el disco USB ($USB_UUID). Conéctalo antes de gestionar copias.${NC}"
            pause_prompt
            return
        fi

        discover_guests
        local backup_path="$MOUNTPOINT/dump"
        mkdir -p "$backup_path"

        mapfile -t BACKUPS < <(
            find "$backup_path" -maxdepth 1 -type f \( \
                -name "vzdump-qemu-*.vma*" -o \
                -name "vzdump-lxc-*.tar*" -o \
                -name "proxmox-host-config-*.tar.gz" -o \
                -name "pve-host-backup-*.tar.gz" \
            \) 2>/dev/null | sort -r
        )
        if [[ -d "$MOUNTPOINT/proxmox-backups" ]]; then
            mapfile -t LEGACY_DIRS < <(find "$MOUNTPOINT/proxmox-backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
            BACKUPS+=("${LEGACY_DIRS[@]}")
        fi

        local count=${#BACKUPS[@]}
        local df_line
        df_line="$(df -Pk "$MOUNTPOINT" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')"
        local tot_kb free_kb used_pct
        read -r tot_kb _ free_kb used_pct <<< "${df_line:-0 0 0 0%}"
        used_pct="${used_pct%%%}"
        local free_gb=$((free_kb / 1024 / 1024))
        local tot_gb=$((tot_kb / 1024 / 1024))

        echo -e " 💽 Almacenamiento USB: $(ui_progress_bar "$used_pct" 18) ${GREEN}${free_gb} GiB libres${NC} de ${tot_gb} GiB"
        echo -e " 📁 Ruta Proxmox VE:    ${CYAN}$backup_path${NC} | Retención: últimas ${BOLD}${KEEP_LAST}${NC} copias por máquina"
        ui_hr

        if [[ "$count" -eq 0 ]]; then
            echo -e "${YELLOW}No se encontraron copias de seguridad en el USB ($backup_path).${NC}"
            ui_hr
            pause_prompt "Presiona [Enter] para volver..."
            return
        fi

        printf " ${GRAY}%-4s %-11s %-20s %-35s %-8s %s${NC}\n" "#" "TIPO" "ID / MÁQUINA" "ARCHIVO" "TAMAÑO" "ANTIGÜEDAD"
        echo -e "${GRAY}────────────────────────────────────────────────────────────────────────────────────────────────${NC}"

        local idx=1
        declare -A BACKUP_MAP
        local now
        now=$(date +%s)

        for bitem in "${BACKUPS[@]}"; do
            local bname bsize btime days_old
            bname="$(basename "$bitem")"
            bsize="$(du -sh "$bitem" 2>/dev/null | awk '{print $1}')"
            btime=$(stat -c %Y "$bitem" 2>/dev/null || echo "$now")
            days_old=$(( (now - btime) / 86400 ))

            local type_str="SESIÓN"
            local type_col="$GRAY"
            local guest_label="-"

            if [[ -f "$bitem" ]]; then
                if [[ "$bname" =~ vzdump-qemu-([0-9]+)- ]]; then
                    local vid="${BASH_REMATCH[1]}"
                    type_str="VM QEMU"
                    type_col="$CYAN"
                    guest_label="$vid (${GUEST_NAMES[$vid]:-VM})"
                elif [[ "$bname" =~ vzdump-lxc-([0-9]+)- ]]; then
                    local cid="${BASH_REMATCH[1]}"
                    type_str="LXC"
                    type_col="$MAGENTA"
                    guest_label="$cid (${GUEST_NAMES[$cid]:-LXC})"
                elif [[ "$bname" =~ (proxmox-host-config|pve-host-backup) ]]; then
                    type_str="HOST PVE"
                    type_col="$YELLOW"
                    guest_label="Host ($(hostname -s 2>/dev/null || echo pve))"
                fi
            fi

            [[ ${#guest_label} -gt 19 ]] && guest_label="${guest_label:0:16}..."
            local disp_file="$bname"
            [[ ${#disp_file} -gt 34 ]] && disp_file="${disp_file:0:31}..."

            printf " ${YELLOW}%2d)${NC}  ${type_col}%-11s${NC} ${BOLD}%-20s${NC} ${GRAY}%-35s${NC} ${GREEN}%-8s${NC} ${CYAN}%dd${NC}\n" \
                "$idx" "$type_str" "$guest_label" "$disp_file" "$bsize" "$days_old"

            BACKUP_MAP["$idx"]="$bitem"
            ((++idx))
        done

        echo -e "${GRAY}────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${YELLOW}t <N>)${NC} 🧪 Probar integridad de la copia N (o ${BOLD}t all${NC} para verificar todo el directorio)"
        echo -e "  ${YELLOW}d <N>)${NC} 🗑️  Eliminar una copia específica (ej: ${BOLD}d 1${NC})"
        echo -e "  ${YELLOW}c    )${NC} 🧹 Purgar antiguas automáticamente (conservar las últimas $KEEP_LAST por máquina)"
        echo -e "  ${YELLOW}r    )${NC} ⚙️  Cambiar política de retención (actual: $KEEP_LAST)"
        echo -e "  ${YELLOW}v / 0)${NC} ↩️  Volver al menú principal"
        ui_hr
        read -rp "👉 Elige una opción: " bopt

        case "$bopt" in
            v|V|0|"") return ;;
            t\ all|T\ ALL|t\ ALL)
                test_backup_integrity "$backup_path"
                pause_prompt
                ;;
            t\ *|T\ *)
                local test_idx
                test_idx="$(echo "$bopt" | awk '{print $2}')"
                if [[ -n "${BACKUP_MAP[$test_idx]:-}" ]]; then
                    test_backup_integrity "${BACKUP_MAP[$test_idx]}"
                    pause_prompt
                fi
                ;;
            r|R)
                read -rp "Número de copias a retener por máquina: " new_keep
                if [[ "$new_keep" =~ ^[0-9]+$ ]] && [ "$new_keep" -ge 1 ]; then
                    KEEP_LAST="$new_keep"
                    save_config
                    echo -e "${GREEN}✓ Retención actualizada a $KEEP_LAST copias.${NC}"
                    sleep 1.2
                fi
                ;;
            c|C)
                if ! ensure_no_backup_running "purgar copias"; then
                    pause_prompt
                    continue
                fi
                echo -e "\n${CYAN}Aplicando política de retención (conservar últimas $KEEP_LAST copias por guest/host)...${NC}"
                prune_old_backups "$backup_path" "$KEEP_LAST" 0
                echo -e "${GREEN}✓ Limpieza completada y SHA256SUMS sincronizado.${NC}"
                sleep 1.8
                ;;
            d\ *|D\ *)
                local del_idx
                del_idx="$(echo "$bopt" | awk '{print $2}')"
                if [[ -n "${BACKUP_MAP[$del_idx]:-}" ]]; then
                    if ! ensure_no_backup_running "borrar copias"; then
                        pause_prompt
                        continue
                    fi
                    local target_del="${BACKUP_MAP[$del_idx]}"
                    echo -e "\n${RED}⚠️ ¿Estás seguro de eliminar PERMANENTEMENTE la copia $(basename "$target_del")?${NC}"
                    read -rp "Escribe SI para confirmar: " conf_del
                    if [[ "$conf_del" == "SI" || "$conf_del" == "si" ]]; then
                        echo "Eliminando..."
                        if [[ -f "$target_del" ]]; then
                            local b_prefix="${target_del%.vma*}"
                            b_prefix="${b_prefix%.tar*}"
                            rm -f "$target_del" "${b_prefix}"* 2>/dev/null || true
                            sync_sha256sums "$backup_path"
                        else
                            rm -rf "$target_del"
                        fi
                        echo -e "${GREEN}✓ Copia eliminada con éxito.${NC}"
                    else
                        echo "Operación cancelada."
                    fi
                    sleep 1.5
                fi
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# MENÚ: Formatear Disco USB a ext4 o exfat
# ─────────────────────────────────────────────────────────────────────────────
menu_format_usb() {
    ui_header "🛠️ ASISTENTE DE FORMATEO DE DISCO USB (EXT4 / EXFAT)"
    echo -e "${RED}${BOLD}⚠️  ¡ATENCIÓN CRÍTICA!${NC}"
    echo -e "El formateo ${RED}${BOLD}DESTRUIRÁ IRREVERSIBLEMENTE TODOS LOS DATOS${NC} del disco seleccionado."
    echo -e "Asegúrate de haber copiado previamente cualquier archivo importante."
    ui_hr

    if ! ensure_no_backup_running "formatear el disco"; then
        pause_prompt "Presiona [Enter] para volver..."
        return
    fi

    load_config
    local dev_path="/dev/disk/by-uuid/$USB_UUID"
    if [[ -z "$USB_UUID" || ! -e "$dev_path" ]]; then
        echo -e "${RED}El disco con UUID ${USB_UUID:-'(no configurado)'} no está conectado físicamente.${NC}"
        pause_prompt "Presiona [Enter] para volver..."
        return
    fi

    local real_device
    real_device="$(readlink -f "$dev_path")"
    local cur_fstype cur_size cur_model
    cur_fstype="$(blkid -s TYPE -o value "$real_device" 2>/dev/null || echo "desconocido")"
    cur_size="$(lsblk -n -o SIZE "$real_device" 2>/dev/null || echo "desconocido")"
    cur_model="$(lsblk -d -n -o MODEL "$real_device" 2>/dev/null || echo "USB")"

    echo -e "Dispositivo a formatear:"
    echo -e "  • Nodo físico:         ${BOLD}$real_device${NC}"
    echo -e "  • Modelo:              $cur_model"
    echo -e "  • Tamaño:              $cur_size"
    echo -e "  • Sistema actual:      ${BOLD}$cur_fstype${NC}"
    echo -e "  • UUID actual:         $USB_UUID"
    ui_hr
    echo "Elige el nuevo sistema de archivos:"
    echo -e "  ${YELLOW}1)${NC} ${BOLD}ext4${NC}  (Recomendado: Nativo Linux / Proxmox, rápido y sin límite de 4GB)"
    echo -e "  ${YELLOW}2)${NC} ${BOLD}exfat${NC} (Compatible con Windows/Mac/Linux, moderno y sin límite de 4GB)"
    echo -e "  ${YELLOW}0)${NC} Cancelar y volver sin tocar nada"
    ui_hr
    read -rp "👉 Opción [0-2]: " fmt_choice

    local target_fs=""
    case "$fmt_choice" in
        1) target_fs="ext4" ;;
        2) target_fs="exfat" ;;
        *) return ;;
    esac

    # Desmontar si está montado
    if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        echo -e "\n${CYAN}Desmontando $MOUNTPOINT de forma segura antes de formatear...${NC}"
        sync
        umount "$MOUNTPOINT" 2>/dev/null || umount -l "$MOUNTPOINT" 2>/dev/null || true
        sleep 1
    fi

    echo -e "\n${RED}=====================================================================${NC}"
    echo -e "${RED}${BOLD}CONFIRMACIÓN DE SEGURIDAD REQUERIDA:${NC}"
    echo -e "Para proceder a formatear ${BOLD}$real_device${NC} en ${BOLD}$target_fs${NC},"
    echo -e "escribe exactamente la palabra ${BOLD}FORMATEAR${NC} en mayúsculas:"
    echo -e "${RED}=====================================================================${NC}"
    read -rp "👉 Confirmación: " confirm_text

    if [[ "$confirm_text" != "FORMATEAR" ]]; then
        echo -e "\nOperación cancelada. El disco NO ha sido modificado."
        pause_prompt
        return
    fi

    echo -e "\n${CYAN}Formateando $real_device en $target_fs con etiqueta 'PROXMOX-BK'...${NC}"
    local fmt_rc=0
    if [[ "$target_fs" == "ext4" ]]; then
        mkfs.ext4 -F -L "PROXMOX-BK" "$real_device" || fmt_rc=$?
    elif [[ "$target_fs" == "exfat" ]]; then
        mkfs.exfat -n "PROXMOX-BK" "$real_device" || fmt_rc=$?
    fi

    if [[ "$fmt_rc" -eq 0 ]]; then
        sync
        sleep 1
        local new_uuid
        new_uuid="$(blkid -s UUID -o value "$real_device" 2>/dev/null || true)"
        if [[ -n "$new_uuid" ]]; then
            USB_UUID="$new_uuid"
            save_config
            echo -e "\n${GREEN}${BOLD}✓ ¡Disco formateado con éxito en $target_fs!${NC}"
            echo -e "Nuevo UUID asignado y guardado: ${BOLD}$USB_UUID${NC}"
            echo -e "${CYAN}Montando el nuevo volumen en $MOUNTPOINT...${NC}"
            if mount_usb_device; then
                MOUNTED_BY_SCRIPT=0
                mkdir -p "$MOUNTPOINT/$BACKUP_ROOT"
                echo -e "${GREEN}✓ Unidad montada y lista para copias de seguridad.${NC}"
            fi
        else
            echo -e "${YELLOW}✓ Formateo completado, pero no se pudo leer el nuevo UUID automáticamente.${NC}"
        fi
    else
        echo -e "${RED}❌ ERROR al formatear el disco (Código: $fmt_rc).${NC}"
    fi

    pause_prompt
}

# ─────────────────────────────────────────────────────────────────────────────
# MENÚ: Centro de Almacenamiento USB (Montar, Desmontar, Cambiar UUID, Formatear)
# ─────────────────────────────────────────────────────────────────────────────
menu_mount_umount_usb() {
    while true; do
        ui_header "🔌 GESTIÓN DEL ALMACENAMIENTO USB (MONTAR / CAMBIAR / FORMATEAR)"

        load_config
        local dev_path="/dev/disk/by-uuid/$USB_UUID"
        local is_mounted=0
        mountpoint -q "$MOUNTPOINT" 2>/dev/null && is_mounted=1

        if [[ "$is_mounted" -eq 1 ]]; then
            local current_src fstype df_line tot_h used_h free_h used_pct
            current_src="$(findmnt -n -o SOURCE --target "$MOUNTPOINT" 2>/dev/null || echo "desconocido")"
            fstype="$(findmnt -n -o FSTYPE --target "$MOUNTPOINT" 2>/dev/null || echo "desconocido")"
            df_line="$(df -h "$MOUNTPOINT" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')"
            read -r tot_h used_h free_h used_pct <<< "${df_line:-0G 0G 0G 0%}"
            local pct_num="${used_pct%%%}"

            echo -e " 📍 Estado actual:     ${GREEN}${BOLD}MONTADO${NC}"
            echo -e " 📁 Punto de montaje:  ${BOLD}$MOUNTPOINT${NC}"
            echo -e " 💽 Dispositivo:       $current_src [$fstype] (UUID: $USB_UUID)"
            echo -e " 📊 Capacidad:         $(ui_progress_bar "$pct_num" 18) Usado: $used_h de $tot_h | ${GREEN}Libre: $free_h${NC}"

            if [[ "$fstype" == "vfat" || "$fstype" == "fat32" ]]; then
                echo -e "\n ${YELLOW}${BOLD}⚠️  ALERTA FAT32: El USB usa FAT32 (límite máx. 4 GiB por archivo).${NC}"
                echo -e " ${YELLOW}   Si una VM comprimida supera 4 GiB fallará. Se recomienda formatear en ext4/exfat.${NC}"
            fi

            ui_hr
            echo -e " ${YELLOW}1)${NC} ⏏️  ${BOLD}Desmontar USB de forma segura${NC} (sync + umount)"
            echo -e " ${YELLOW}2)${NC} 💽 ${BOLD}Cambiar / Detectar otro disco USB externo${NC} (Seleccionar UUID)"
            echo -e " ${YELLOW}3)${NC} 📂 Explorar contenido del punto de montaje ($MOUNTPOINT)"
            echo -e " ${YELLOW}4)${NC} 🛠️  ${BOLD}Formatear Disco USB${NC} (ext4 / exfat) [Elimina límite 4GB]"
            echo -e " ${YELLOW}0)${NC} ↩️  Volver al menú principal"
            ui_hr
            read -rp "👉 Elige una opción [0-4]: " m_opt

            case "$m_opt" in
                1)
                    if ! ensure_no_backup_running "desmontar el USB"; then
                        pause_prompt
                        continue
                    fi
                    echo -e "\n${CYAN}Sincronizando escrituras pendientes a disco...${NC}"
                    sync
                    echo "Desmontando $MOUNTPOINT..."
                    if umount "$MOUNTPOINT" 2>/dev/null || umount -l "$MOUNTPOINT" 2>/dev/null; then
                        MOUNTED_BY_SCRIPT=0
                        echo -e "${GREEN}✓ Disco USB desmontado correctamente.${NC} Ya puedes desconectarlo de forma segura."
                    else
                        echo -e "${RED}ERROR: No se pudo desmontar el punto $MOUNTPOINT.${NC}"
                        echo "Posibles procesos utilizando el directorio:"
                        fuser -mv "$MOUNTPOINT" 2>/dev/null || true
                    fi
                    pause_prompt
                    ;;
                2)
                    menu_select_usb
                    ;;
                3)
                    ui_header "📂 CONTENIDO DE $MOUNTPOINT"
                    ls -lah "$MOUNTPOINT" "$MOUNTPOINT/dump" 2>/dev/null || true
                    pause_prompt
                    ;;
                4)
                    menu_format_usb
                    ;;
                0|"")
                    return
                    ;;
            esac
        else
            echo -e " 📍 Estado actual:     ${YELLOW}${BOLD}DESMONTADO${NC}"
            echo -e " 📁 Punto de montaje:  $MOUNTPOINT"
            echo -e " 🏷️  UUID configurado:  $USB_UUID"

            local connected_device=""
            local fstype=""
            if [[ -n "$USB_UUID" && -e "$dev_path" ]]; then
                connected_device="$(readlink -f "$dev_path")"
                fstype="$(blkid -s TYPE -o value "$connected_device" 2>/dev/null || echo "desconocido")"
                echo -e " 💽 Dispositivo físico: ${GREEN}Conectado en $connected_device [$fstype]${NC}"
            else
                echo -e " 💽 Dispositivo físico: ${RED}NO DETECTADO en /dev/disk/by-uuid/${USB_UUID:-<sin-uuid>}${NC}"
            fi

            if [[ "$fstype" == "vfat" || "$fstype" == "fat32" ]]; then
                echo -e "\n ${YELLOW}${BOLD}⚠️  ALERTA FAT32: El USB usa FAT32 (límite máx. 4 GiB por archivo).${NC}"
                echo -e " ${YELLOW}   Si una VM comprimida supera 4 GiB fallará. Se recomienda formatear en ext4/exfat.${NC}"
            fi

            ui_hr
            echo -e " ${YELLOW}1)${NC} 🔌 ${BOLD}Montar USB ahora${NC} en $MOUNTPOINT"
            echo -e " ${YELLOW}2)${NC} 💽 ${BOLD}Cambiar / Seleccionar otro disco USB externo${NC} (UUID)"
            echo -e " ${YELLOW}3)${NC} 🛠️  ${BOLD}Formatear Disco USB${NC} (ext4 / exfat) [Elimina límite 4GB]"
            echo -e " ${YELLOW}0)${NC} ↩️  Volver al menú principal"
            ui_hr
            read -rp "👉 Elige una opción [0-3]: " m_opt

            case "$m_opt" in
                1)
                    echo -e "\n${CYAN}Montando disco USB ($USB_UUID)...${NC}"
                    if mount_usb_device; then
                        MOUNTED_BY_SCRIPT=0
                        echo -e "${GREEN}✓ Disco USB montado con éxito en $MOUNTPOINT.${NC}"
                        df -h "$MOUNTPOINT" 2>/dev/null || true
                    else
                        echo -e "${RED}ERROR: No se pudo montar el disco USB.${NC} Asegúrate de que esté conectado y el UUID sea correcto."
                    fi
                    pause_prompt
                    ;;
                2)
                    menu_select_usb
                    ;;
                3)
                    menu_format_usb
                    ;;
                0|"")
                    return
                    ;;
            esac
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# MENÚ: Restaurar una Copia de Seguridad (VMs QEMU, LXC o Configuración Host)
# ─────────────────────────────────────────────────────────────────────────────
# Estado compartido entre las fases de la restauración (se reinicia en cada uso del menú)
RESTORE_ARCHIVES=()           # Copias encontradas en el USB (más recientes primero)
declare -A RESTORE_ARCHIVE_MAP=()      # Número de la tabla -> ruta del archivo
declare -A RESTORE_ARCHIVE_ORIG_ID=()  # Número de la tabla -> ID original (o "Host")
RESTORE_CONTINUE=0            # 1 = la fase anterior permite continuar
RESTORE_SELECTED_FILE=""      # Copia elegida
RESTORE_ORIG_ID=""            # ID original de la copia elegida
RESTORE_IS_VM=0               # 1 = VM QEMU, 0 = LXC
RESTORE_FORCE_FLAG=""         # "--force 1" si se sobrescribe un ID existente
RESTORE_START_FLAG=""         # "--start 1" si se arranca al terminar

# Orquestador de la restauración: busca las copias del USB, deja elegir una y la restaura según su tipo
# (configuración del host o VM/LXC). Las fases restaurar_* comparten su estado mediante las globales RESTORE_*.
menu_restore_backup() {
    ui_header "🔄 RESTAURACIÓN DE COPIAS DE SEGURIDAD"

    restaurar_buscar_copias
    [[ "$RESTORE_CONTINUE" -eq 1 ]] || return 0
    restaurar_elegir_copia
    [[ -n "$RESTORE_SELECTED_FILE" ]] || return 0

    # Caso 1: Host Backup
    if [[ "$(basename "$RESTORE_SELECTED_FILE")" =~ (pve-host-backup-|proxmox-host-config-) ]]; then
        restaurar_copia_host
        return 0
    fi

    # Caso 2: Máquina Virtual QEMU o Contenedor LXC
    restaurar_pedir_id_destino
    [[ "$RESTORE_CONTINUE" -eq 1 ]] || return 0
    restaurar_pedir_opciones
    restaurar_confirmar
    [[ "$RESTORE_CONTINUE" -eq 1 ]] || return 0
    restaurar_ejecutar
}

# Monta el USB y localiza las copias restaurables (dump/ y la carpeta antigua proxmox-backups/) en RESTORE_ARCHIVES.
# Deja RESTORE_CONTINUE=1 si hay alguna; si no, avisa y espera [Enter].
restaurar_buscar_copias() {
    RESTORE_CONTINUE=0
    RESTORE_ARCHIVES=()

    if ! mount_usb_device; then
        echo -e "${RED}ERROR: No se pudo acceder ni montar el disco USB ($USB_UUID).${NC}"
        pause_prompt "Presiona [Enter] para volver..."
        return 0
    fi

    discover_guests
    local backup_path="$MOUNTPOINT/dump"
    if [[ ! -d "$backup_path" && ! -d "$MOUNTPOINT/proxmox-backups" ]]; then
        echo -e "${YELLOW}No existe la carpeta de respaldos en el USB.${NC}"
        pause_prompt "Presiona [Enter] para volver..."
        return 0
    fi

    local search_paths=()
    [[ -d "$MOUNTPOINT/dump" ]] && search_paths+=("$MOUNTPOINT/dump")
    [[ -d "$MOUNTPOINT/proxmox-backups" ]] && search_paths+=("$MOUNTPOINT/proxmox-backups")

    mapfile -t RESTORE_ARCHIVES < <(
        find "${search_paths[@]}" -type f \( \
            -name "vzdump-qemu-*.vma*" -o \
            -name "vzdump-lxc-*.tar*" -o \
            -name "pve-host-backup-*.tar.gz" -o \
            -name "proxmox-host-config-*.tar.gz" \
        \) 2>/dev/null | sort -r
    )

    if [[ ${#RESTORE_ARCHIVES[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No se encontraron archivos de backup (.vma.zst, .tar.zst, .tar.gz) en el USB.${NC}"
        pause_prompt "Presiona [Enter] para volver..."
        return 0
    fi
    RESTORE_CONTINUE=1
    return 0
}

# Imprime la tabla numerada de RESTORE_ARCHIVES (tipo, ID original, archivo, tamaño, fecha) y rellena
# RESTORE_ARCHIVE_MAP / RESTORE_ARCHIVE_ORIG_ID (número de la tabla -> archivo / ID original)
restaurar_mostrar_tabla() {
    echo -e "Copias disponibles para restaurar (${BOLD}${#RESTORE_ARCHIVES[@]}${NC} encontradas):\n"
    printf " ${GRAY}%-4s %-11s %-20s %-36s %-8s %s${NC}\n" "#" "TIPO" "ID ORIGINAL" "ARCHIVO" "TAMAÑO" "FECHA"
    echo -e "${GRAY}────────────────────────────────────────────────────────────────────────────────────────────────${NC}"

    local idx=1
    RESTORE_ARCHIVE_MAP=()
    RESTORE_ARCHIVE_ORIG_ID=()

    for arch in "${RESTORE_ARCHIVES[@]}"; do
        local bfile bsize bdate
        bfile="$(basename "$arch")"
        bsize="$(du -sh "$arch" 2>/dev/null | awk '{print $1}')"
        bdate="$(date -r "$arch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "-")"

        local type_str="OTRO"
        local type_col="$GRAY"
        local orig_id="-"
        local id_label="-"

        if [[ "$bfile" =~ vzdump-qemu-([0-9]+)- ]]; then
            orig_id="${BASH_REMATCH[1]}"
            type_str="VM QEMU"
            type_col="$CYAN"
            id_label="$orig_id (${GUEST_NAMES[$orig_id]:-VM})"
        elif [[ "$bfile" =~ vzdump-lxc-([0-9]+)- ]]; then
            orig_id="${BASH_REMATCH[1]}"
            type_str="LXC"
            type_col="$MAGENTA"
            id_label="$orig_id (${GUEST_NAMES[$orig_id]:-LXC})"
        elif [[ "$bfile" =~ (pve-host-backup-|proxmox-host-config-) ]]; then
            orig_id="Host"
            type_str="HOST PVE"
            type_col="$YELLOW"
            id_label="Host Config"
        fi

        [[ ${#id_label} -gt 19 ]] && id_label="${id_label:0:16}..."
        local disp_file="$bfile"
        [[ ${#disp_file} -gt 35 ]] && disp_file="${disp_file:0:32}..."

        printf " ${YELLOW}%2d)${NC}  ${type_col}%-11s${NC} ${BOLD}%-20s${NC} ${GRAY}%-36s${NC} ${GREEN}%-8s${NC} ${CYAN}%s${NC}\n" \
            "$idx" "$type_str" "$id_label" "$disp_file" "$bsize" "$bdate"

        RESTORE_ARCHIVE_MAP["$idx"]="$arch"
        RESTORE_ARCHIVE_ORIG_ID["$idx"]="$orig_id"
        ((++idx))
    done
    return 0
}

# Muestra la tabla y pide el número de copia: deja RESTORE_SELECTED_FILE y RESTORE_ORIG_ID (vacío = volver)
restaurar_elegir_copia() {
    RESTORE_SELECTED_FILE=""
    RESTORE_ORIG_ID=""
    restaurar_mostrar_tabla

    echo -e "${GRAY}────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "Elige el número de la copia que deseas restaurar o ${BOLD}0${NC} para volver."
    ui_hr
    read -rp "👉 Selecciona una copia [1-${#RESTORE_ARCHIVES[@]}, 0]: " sel_arch

    [[ "$sel_arch" == "0" || -z "$sel_arch" ]] && return 0
    local selected_file="${RESTORE_ARCHIVE_MAP[$sel_arch]:-}"
    if [[ -z "$selected_file" ]]; then
        echo "Opción no válida."
        sleep 1
        return 0
    fi

    RESTORE_SELECTED_FILE="$selected_file"
    RESTORE_ORIG_ID="${RESTORE_ARCHIVE_ORIG_ID[$sel_arch]}"
    return 0
}

# Restaura una copia de configuración del host: extracción de revisión en /tmp o directamente sobre /
restaurar_copia_host() {
    local selected_file="$RESTORE_SELECTED_FILE"
    local base_file
    base_file="$(basename "$selected_file")"

    ui_header "🖥️ RESTAURAR COPIA DE CONFIGURACIÓN DEL HOST"
    echo -e "Archivo seleccionado: ${BOLD}$base_file${NC}"
    echo -e "\nEsta copia contiene configuraciones críticas de Proxmox:"
    echo -e "  • /etc/pve (Cluster y configs de VMs/LXCs)"
    echo -e "  • /etc/network/interfaces (Red)"
    echo -e "  • /etc/hosts, /etc/resolv.conf, crontabs..."
    ui_hr
    echo -e " ${YELLOW}1)${NC} 📂 Extraer en carpeta temporal (/tmp/pve-host-restore-preview) para revisar"
    echo -e " ${YELLOW}2)${NC} ⚠️  Restaurar directamente al sistema raíz (/) [¡SOBRESCRIBE CONFIGS!]"
    echo -e " ${YELLOW}0)${NC} ↩️  Cancelar"
    ui_hr
    read -rp "👉 Opción [0-2]: " host_opt

    case "$host_opt" in
        1)
            local tmp_dest
            tmp_dest="/tmp/pve-host-restore-preview-$(date +%s)"
            mkdir -p "$tmp_dest"
            echo "Extrayendo en $tmp_dest..."
            tar -xzvf "$selected_file" -C "$tmp_dest"
            echo -e "\n${GREEN}✓ Archivos extraídos con éxito en:${NC} $tmp_dest"
            pause_prompt
            ;;
        2)
            if ask_yes_no "⚠️ ¿Estás COMPLETAMENTE SEGURO de restaurar la configuración en / ? Podría alterar la red." "n"; then
                echo "Restaurando configuración del host..."
                tar -xzvf "$selected_file" -C /
                echo -e "\n${GREEN}✓ Configuración del host restaurada con éxito.${NC}"
                pause_prompt
            fi
            ;;
    esac
    return 0
}

# VM/LXC (1/4): cabecera del asistente, ID de destino (target_id) y, si ya existe, apagado y confirmación de
# sobrescritura (RESTORE_FORCE_FLAG). Deja RESTORE_IS_VM y RESTORE_CONTINUE=1 si se puede seguir.
restaurar_pedir_id_destino() {
    RESTORE_CONTINUE=0
    RESTORE_FORCE_FLAG=""
    local orig_id="$RESTORE_ORIG_ID"
    local base_file
    base_file="$(basename "$RESTORE_SELECTED_FILE")"

    RESTORE_IS_VM=0
    [[ "$base_file" =~ vzdump-qemu- ]] && RESTORE_IS_VM=1

    if [[ "$RESTORE_IS_VM" -eq 1 ]]; then
        ui_header "🔄 ASISTENTE DE RESTAURACIÓN DE MÁQUINA VIRTUAL (QEMU)"
    else
        ui_header "🔄 ASISTENTE DE RESTAURACIÓN DE CONTENEDOR (LXC)"
    fi
    echo -e "• Archivo origen:  ${BOLD}$base_file${NC}"
    echo -e "• ID original:     ${BOLD}$orig_id${NC} (${GUEST_NAMES[$orig_id]:-nuevo})"
    ui_hr

    read -rp "👉 Introduce el ID de destino en Proxmox [Enter para mantener $orig_id]: " target_id
    target_id="${target_id:-$orig_id}"

    if ! [[ "$target_id" =~ ^[0-9]+$ ]] || [ "$target_id" -lt 100 ]; then
        echo -e "${RED}ERROR: El ID de Proxmox debe ser un número entero >= 100.${NC}"
        pause_prompt
        return 0
    fi

    local id_exists=0
    local is_running=0
    if [[ "$RESTORE_IS_VM" -eq 1 ]]; then
        if qm status "$target_id" >/dev/null 2>&1; then
            id_exists=1
            qm status "$target_id" 2>/dev/null | grep -q "status: running" && is_running=1
        fi
    else
        if pct status "$target_id" >/dev/null 2>&1; then
            id_exists=1
            pct status "$target_id" 2>/dev/null | grep -q "status: running" && is_running=1
        fi
    fi

    if [[ "$id_exists" -eq 1 ]]; then
        echo -e "\n${YELLOW}⚠️ ATENCIÓN: El ID $target_id YA EXISTE actualmente en Proxmox.${NC}"
        if [[ "$is_running" -eq 1 ]]; then
            echo -e "${RED}La máquina/contenedor $target_id está en ejecución.${NC}"
            if ask_yes_no "¿Deseas apagarla ahora para poder restaurar?" "n"; then
                echo "Deteniendo ID $target_id..."
                if [[ "$RESTORE_IS_VM" -eq 1 ]]; then
                    qm stop "$target_id" || qm stop "$target_id" --skiplock 1 || true
                else
                    pct stop "$target_id" || true
                fi
                sleep 2
            else
                echo "Operación cancelada. No se puede restaurar sobre una máquina en ejecución."
                pause_prompt
                return 0
            fi
        fi

        echo -e "${RED}⚠️ Para restaurar en un ID existente, se DESTRUIRÁN y reemplazarán sus datos actuales.${NC}"
        if ! ask_yes_no "¿Confirmas que deseas SOBRESCRIBIR completamente el ID $target_id?" "n"; then
            echo "Operación cancelada por el usuario."
            pause_prompt
            return 0
        fi
        RESTORE_FORCE_FLAG="--force 1"
    fi
    RESTORE_CONTINUE=1
    return 0
}

# VM/LXC (2/4): storage de destino (target_storage) y arranque automático tras restaurar (RESTORE_START_FLAG)
restaurar_pedir_opciones() {
    echo -e "\n${BOLD}Almacenamientos disponibles en el nodo:${NC}"
    pvesm status 2>/dev/null || true
    echo
    read -rp "👉 Introduce el Storage donde crear los discos (ej: local-lvm) [Enter para predeterminado]: " target_storage
    target_storage="$(echo "$target_storage" | tr -d ' ')"

    RESTORE_START_FLAG=""
    if ask_yes_no "¿Deseas iniciar automáticamente el ID $target_id tras restaurar?" "n"; then
        RESTORE_START_FLAG="--start 1"
    fi
    return 0
}

# VM/LXC (3/4): resumen de la restauración y confirmación final (RESTORE_CONTINUE=1 si se confirma)
restaurar_confirmar() {
    RESTORE_CONTINUE=0
    ui_header "✅ CONFIRMACIÓN DE RESTAURACIÓN"
    echo -e "• Archivo origen:     $RESTORE_SELECTED_FILE"
    echo -e "• Tipo:               $([ "$RESTORE_IS_VM" -eq 1 ] && echo "VM QEMU" || echo "Contenedor LXC")"
    echo -e "• ID Destino:         ${BOLD}$target_id${NC}"
    echo -e "• Storage Destino:    ${BOLD}${target_storage:-"(Predeterminado por la copia)"}${NC}"
    echo -e "• Sobrescribir:       $([ -n "$RESTORE_FORCE_FLAG" ] && echo "${RED}SÍ (Destructivo)${NC}" || echo "${GREEN}No (Nuevo ID)${NC}")"
    echo -e "• Iniciar al acabar:  $([ -n "$RESTORE_START_FLAG" ] && echo "SÍ" || echo "No")"
    ui_hr

    if ! ask_yes_no "¿Estás seguro de iniciar la restauración ahora?" "s"; then
        echo "Restauración cancelada."
        pause_prompt
        return 0
    fi
    RESTORE_CONTINUE=1
    return 0
}

# VM/LXC (4/4): ejecuta qmrestore / pct restore con las opciones elegidas y muestra el resultado
restaurar_ejecutar() {
    local selected_file="$RESTORE_SELECTED_FILE"
    local force_flag="$RESTORE_FORCE_FLAG" start_flag="$RESTORE_START_FLAG"

    echo -e "\n${CYAN}Iniciando proceso de restauración...${NC}\n"

    local cmd_rc=0
    local storage_arg=""
    [[ -n "$target_storage" ]] && storage_arg="--storage $target_storage"

    if [[ "$RESTORE_IS_VM" -eq 1 ]]; then
        qm unlock "$target_id" 2>/dev/null || true
        log_info "Ejecutando qmrestore $selected_file $target_id $storage_arg $force_flag $start_flag"
        # shellcheck disable=SC2086
        qmrestore "$selected_file" "$target_id" $storage_arg $force_flag $start_flag || cmd_rc=$?
    else
        pct unlock "$target_id" 2>/dev/null || true
        log_info "Ejecutando pct restore $target_id $selected_file $storage_arg $force_flag $start_flag"
        # shellcheck disable=SC2086
        pct restore "$target_id" "$selected_file" $storage_arg $force_flag $start_flag || cmd_rc=$?
    fi

    echo
    ui_hr
    if [[ "$cmd_rc" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✓ ¡RESTAURACIÓN COMPLETADA CON ÉXITO PARA EL ID $target_id!${NC}"
        log_info "Restauración de ID $target_id completada con éxito."
    else
        echo -e "${RED}${BOLD}❌ ERROR EN LA RESTAURACIÓN (Código de salida: $cmd_rc)${NC}"
        log_err "Fallo al restaurar ID $target_id desde $selected_file (Código: $cmd_rc)."
    fi

    pause_prompt
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. MENÚ: Gestionar Discos y Passthrough de VMs y Contenedores LXC (backup=0 / backup=1)
# ─────────────────────────────────────────────────────────────────────────────
menu_manage_disks() {
    while true; do
        ui_header "⚙️ GESTIÓN DE DISCOS Y PASSTHROUGH (VMs QEMU Y CONTENEDORES LXC)"
        echo -e "Permite marcar discos o puntos de montaje con ${BOLD}backup=0${NC} para evitar que"
        echo -e "vzdump intente respaldar discos mecánicos o passthrough gigantes en el USB."
        ui_hr

        discover_guests
        if [[ ${#ALL_GUEST_IDS[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No se detectaron máquinas virtuales ni contenedores LXC en este nodo.${NC}"
            pause_prompt "Presiona [Enter] para volver..."
            return
        fi

        echo -e "${BOLD}Máquinas y Contenedores disponibles:${NC}\n"
        local i=1
        declare -A GUEST_INDEX_MAP
        for gid in "${ALL_GUEST_IDS[@]}"; do
            local gtype="${GUEST_TYPES[$gid]}"
            local gsz
            gsz="$(estimate_guest_disk_gb "$gid")"
            printf "  ${YELLOW}%2d)${NC} [ID ${BOLD}%-4s${NC}] %-10s ${BOLD}%-24s${NC} (%s) ──> Backup actual: ${CYAN}~%s GiB${NC}\n" \
                "$i" "$gid" "$gtype" "${GUEST_NAMES[$gid]}" "${GUEST_STATUS[$gid]}" "$gsz"
            GUEST_INDEX_MAP["$i"]="$gid"
            ((++i))
        done

        echo -e "\n  ${YELLOW}a)${NC} 🛡️ EXCLUIR AUTOMÁTICAMENTE todos los discos passthrough (/dev/...) en todas las máquinas"
        echo -e "  ${YELLOW}v)${NC} ↩️  Volver al menú principal"
        ui_hr
        read -rp "👉 Elige una máquina [1-$((i-1)) / a / v]: " vm_choice

        if [[ "$vm_choice" =~ ^[vV0]$ || -z "$vm_choice" ]]; then
            return
        fi

        if [[ "$vm_choice" =~ ^[aA]$ ]]; then
            echo -e "\n${CYAN}Buscando discos passthrough (/dev/...) sin backup=0 en todas las máquinas...${NC}"
            local modified_count=0
            for gid in "${ALL_GUEST_IDS[@]}"; do
                local conf_file="/etc/pve/qemu-server/${gid}.conf"
                [[ "${GUEST_TYPES[$gid]}" == "LXC" ]] && conf_file="/etc/pve/lxc/${gid}.conf"
                [[ -f "$conf_file" ]] || continue

                while read -r dline; do
                    [[ -z "$dline" ]] && continue
                    local disk_id
                    disk_id="$(echo "$dline" | cut -d':' -f1 | tr -d ' ')"
                    echo -e "  • ID $gid (${GUEST_NAMES[$gid]}): Excluyendo ${BOLD}$disk_id${NC} (passthrough)..."
                    conf_disk_backup_off "$conf_file" "$disk_id"
                    ((++modified_count))
                done < <(conf_passthrough_without_backup0 "$conf_file")
            done
            echo -e "${GREEN}✓ Operación completada. Se protegieron $modified_count disco(s) passthrough.${NC}"
            pause_prompt
            continue
        fi

        local selected_gid="${GUEST_INDEX_MAP[$vm_choice]:-}"
        if [[ -z "$selected_gid" ]]; then
            continue
        fi

        local selected_type="${GUEST_TYPES[$selected_gid]}"
        local conf_file="/etc/pve/qemu-server/${selected_gid}.conf"
        local disk_regex="^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]+:"
        if [[ "$selected_type" == "LXC" ]]; then
            conf_file="/etc/pve/lxc/${selected_gid}.conf"
            disk_regex="^(rootfs|mp[0-9]+):"
        fi

        if [[ ! -f "$conf_file" ]]; then
            echo -e "${RED}No se encontró el fichero de configuración $conf_file.${NC}"
            pause_prompt
            continue
        fi

        while true; do
            ui_header "💽 DISCOS DE $selected_type $selected_gid (${GUEST_NAMES[$selected_gid]})"

            mapfile -t DISK_LINES < <(conf_main_section "$conf_file" | grep -E "$disk_regex" || true)

            if [[ ${#DISK_LINES[@]} -eq 0 ]]; then
                echo "No se encontraron discos definidos en este elemento."
                pause_prompt
                break
            fi

            local d_idx=1
            declare -A DISK_MAP
            for dline in "${DISK_LINES[@]}"; do
                local d_key d_val d_gb
                d_key="$(echo "$dline" | cut -d':' -f1 | tr -d ' ')"
                d_val="$(echo "$dline" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
                d_gb="$(parse_disk_size_gb "$d_val")"

                local status_tag="${GREEN}[INCLUIDO EN BACKUP]${NC}"
                local is_passthrough="${GRAY}(disco virtual ~${d_gb} GiB)${NC}"
                [[ "$d_val" =~ /dev/ ]] && is_passthrough="${YELLOW}(PASSTHROUGH FÍSICO ~${d_gb} GiB)${NC}"

                if [[ "$d_key" == "rootfs" ]]; then
                    status_tag="${CYAN}[SISTEMA RAÍZ LXC - SIEMPRE INCLUIDO]${NC}"
                elif [[ "$d_val" =~ backup=(0|no) ]]; then
                    status_tag="${RED}[EXCLUIDO: backup=0]${NC}"
                fi

                echo -e "  ${YELLOW}$d_idx)${NC} ${BOLD}$d_key${NC} $is_passthrough ──> $status_tag"
                echo -e "      └─> ${GRAY}$d_val${NC}"
                DISK_MAP["$d_idx"]="$d_key"
                ((++d_idx))
            done

            ui_hr
            echo -e "Escribe el número del disco para alternar su estado (Incluir/Excluir)"
            echo -e "o escribe ${BOLD}v${NC} para volver al listado de máquinas."
            ui_hr
            read -rp "👉 Opción: " disk_sel

            [[ "$disk_sel" =~ ^[vV0]$ || -z "$disk_sel" ]] && break

            local target_key="${DISK_MAP[$disk_sel]:-}"
            if [[ "$target_key" == "rootfs" ]]; then
                echo -e "${YELLOW}⚠️ El disco raíz (rootfs) de un contenedor LXC no se puede excluir con backup=0.${NC}"
                sleep 1.5
                continue
            fi

            if [[ -n "$target_key" ]]; then
                local current_line
                current_line="$(conf_main_section "$conf_file" | grep "^${target_key}:" || true)"
                if [[ "$current_line" =~ backup=(0|no) ]]; then
                    conf_disk_backup_on "$conf_file" "$target_key"
                    echo -e "${GREEN}✓ Disco $target_key marcado como INCLUIDO en el backup.${NC}"
                else
                    conf_disk_backup_off "$conf_file" "$target_key"
                    echo -e "${YELLOW}✓ Disco $target_key marcado como EXCLUIDO (backup=0).${NC}"
                fi
                sleep 1
            fi
        done
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. MENÚ: Calculadora de Espacio Requerido vs Disponible en USB
# ─────────────────────────────────────────────────────────────────────────────
menu_disk_calculator() {
    ui_header "📊 ESTIMACIÓN DE ESPACIO DE BACKUP VS DISCO USB"
    echo -e "Regla de inclusión de Proxmox vzdump:"
    echo -e "  • ${GREEN}[INCLUIDO]${NC} Discos virtuales, puntos de montaje y passthrough (/dev/...) sin backup=0."
    echo -e "  • ${RED}[EXCLUIDO]${NC} Discos marcados con backup=0 o backup=no en su configuración."
    ui_hr

    discover_guests
    local total_req=0
    local any_passthrough_included=0

    echo -e "\n 🖥️  ${BOLD}[HOST]${NC} Configuración Proxmox VE, PVE cluster, red: ${GREEN}~1 GiB${NC}"
    total_req=$((total_req + 1))

    for gid in "${ALL_GUEST_IDS[@]}"; do
        local gname="${GUEST_NAMES[$gid]}"
        local gtype="${GUEST_TYPES[$gid]}"
        local gstatus="${GUEST_STATUS[$gid]}"
        local gsz
        gsz="$(estimate_guest_disk_gb "$gid")"
        total_req=$((total_req + gsz))

        echo -e "\n 📦 ${BOLD}[ID $gid]${NC} $gtype ${BOLD}$gname${NC} ($gstatus) ──> Total backup: ${YELLOW}~$gsz GiB${NC}"

        local disk_regex="^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]+:"
        [[ "$gtype" == "LXC" ]] && disk_regex="^(rootfs|mp[0-9]+):"

        while read -r dline; do
            [[ "$dline" =~ ^\[.*\] ]] && break
            [[ "$dline" =~ $disk_regex ]] || continue

            local d_key d_val d_gb is_pt=0
            d_key="$(echo "$dline" | cut -d':' -f1 | tr -d ' ')"
            d_val="$(echo "$dline" | cut -d':' -f2- | sed 's/^[[:space:]]*//')"
            [[ "$d_val" =~ /dev/ ]] && is_pt=1
            d_gb="$(parse_disk_size_gb "$d_val")"

            if [[ "$d_val" =~ backup=(0|no) ]]; then
                echo -e "      ├─ $d_key (~${d_gb} GiB): ${RED}[EXCLUIDO: backup=0]${NC} ${GRAY}($([ "$is_pt" -eq 1 ] && echo "Passthrough" || echo "Virtual"))${NC} -> 0 GiB al backup"
            else
                if [[ "$is_pt" -eq 1 ]]; then
                    echo -e "      ├─ $d_key (~${d_gb} GiB): ${YELLOW}${BOLD}[⚠️ PASSTHROUGH INCLUIDO]${NC} -> ${YELLOW}+${d_gb} GiB al backup${NC}"
                    any_passthrough_included=1
                else
                    echo -e "      ├─ $d_key (~${d_gb} GiB): ${GREEN}[INCLUIDO]${NC} (Disco Virtual) -> +${d_gb} GiB al backup"
                fi
            fi
        done < <(get_guest_config "$gid" "$gtype")
    done

    echo
    ui_hr
    echo -e "${BOLD}ESPACIO TOTAL ESTIMADO REQUERIDO:${NC} ${YELLOW}${BOLD}~${total_req} GiB${NC}"

    local dev_path="/dev/disk/by-uuid/$USB_UUID"
    if [[ -n "$USB_UUID" && -e "$dev_path" ]]; then
        if mount_usb_device; then
            local free_kb
            free_kb="$(df -Pk "$MOUNTPOINT" | awk 'NR==2 {print $4}')"
            local free_gb=$((free_kb / 1024 / 1024))
            echo -e "${BOLD}ESPACIO LIBRE DISPONIBLE EN USB:${NC} ${GREEN}${BOLD}${free_gb} GiB${NC}"
            ui_hr
            if (( free_gb >= total_req + MIN_FREE_GB )); then
                echo -e "${GREEN}${BOLD}✓ ¡Espacio suficiente! El backup cabe dentro de la capacidad libre del USB.${NC}"
            else
                echo -e "${RED}${BOLD}❌ ATENCIÓN: El espacio libre ($free_gb GiB) es INSUFICIENTE para respaldar ~${total_req} GiB.${NC}"
                if [[ "$any_passthrough_included" -eq 1 ]]; then
                    echo -e "${YELLOW}👉 Se detectaron discos PASSTHROUGH físicos incluidos en el backup.${NC}"
                    echo -e "${YELLOW}   Exclúyelos con 'backup=0' (pulsando 'g') para que la copia quepa en el USB.${NC}"
                fi
            fi
        fi
    else
        echo -e "${RED}El disco USB ($USB_UUID) no está conectado actualmente.${NC}"
    fi

    ui_hr
    if [[ "$any_passthrough_included" -eq 1 ]]; then
        echo -e "  ${YELLOW}g)${NC} ⚙️  Ir al Gestor de Discos para excluir passthrough (backup=0)"
    fi
    echo -e "  ${YELLOW}v)${NC} ↩️  Volver al menú principal"
    ui_hr
    read -rp "👉 Opción: " calc_opt
    if [[ "$calc_opt" =~ ^[gG]$ && "$any_passthrough_included" -eq 1 ]]; then
        menu_manage_disks
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Módulo de Notificaciones (Telegram, Proxmox VE y Email)
# ─────────────────────────────────────────────────────────────────────────────
get_proxmox_notification_targets() {
    local notif_file="/etc/pve/notifications.cfg"
    local targets=()
    if [[ -f "$notif_file" ]]; then
        while read -r type name; do
            type="${type%:}"
            [[ -n "$name" ]] && targets+=("$name:$type")
        done < <(grep -E '^(smtp|sendmail|gotify):' "$notif_file" 2>/dev/null)
    fi
    printf '%s\n' "${targets[@]}"
}

select_proxmox_notification_target() {
    ui_header "🎯 SELECCIÓN DE DESTINO DE NOTIFICACIÓN DE PROXMOX VE"
    echo -e "Destinos configurados en ${BOLD}Centro de Datos -> Notificaciones${NC}:\n"

    local targets=()
    mapfile -t targets < <(get_proxmox_notification_targets)

    declare -A TARGET_MAP
    local idx=1

    if [[ ${#targets[@]} -gt 0 ]]; then
        for item in "${targets[@]}"; do
            [[ -z "$item" ]] && continue
            local t_name="${item%:*}"
            local t_type="${item#*:}"
            local cur_tag=""
            if [[ "$t_name" == "$NOTIFICATION_TARGET" ]]; then
                cur_tag=" ${GREEN}${BOLD}[SELECCIONADO]${NC}"
            fi
            echo -e "  ${YELLOW}$idx)${NC} ${BOLD}$t_name${NC} [Tipo: ${CYAN}$t_type${NC}]$cur_tag"
            TARGET_MAP["$idx"]="$t_name"
            ((++idx))
        done
    else
        echo -e "${YELLOW}No se encontraron destinos en /etc/pve/notifications.cfg.${NC}"
        echo -e "Puedes escribir manualmente el nombre del destino que tengas en Proxmox."
    fi

    echo -e "\n  ${YELLOW}m)${NC} Introducir nombre de destino manualmente (ej: Gmail-Alertas)"
    echo -e "  ${YELLOW}0)${NC} Cancelar y volver"
    ui_hr
    read -rp "👉 Selecciona una opción [1-$((idx-1)) / m / 0]: " sel_t

    case "$sel_t" in
        0|"") return ;;
        m|M)
            read -rp "Introduce el nombre exacto del destino de Proxmox: " man_t
            man_t="$(echo "$man_t" | tr -d ' ')"
            if [[ -n "$man_t" ]]; then
                NOTIFICATION_TARGET="$man_t"
                EMAIL_ENABLED=1
                save_config
                echo -e "${GREEN}✓ Destino configurado a: $NOTIFICATION_TARGET${NC}"
                sleep 1.5
            fi
            ;;
        *)
            if [[ -n "${TARGET_MAP[$sel_t]:-}" ]]; then
                NOTIFICATION_TARGET="${TARGET_MAP[$sel_t]}"
                EMAIL_ENABLED=1
                save_config
                echo -e "${GREEN}✓ Destino configurado a: $NOTIFICATION_TARGET${NC}"
                sleep 1.5
            fi
            ;;
    esac
}

menu_notifications() {
    load_config
    while true; do
        ui_header "🔔 CONFIGURACIÓN DE NOTIFICACIONES (TELEGRAM Y PROXMOX VE)"

        local tg_txt="${RED}DESACTIVADO${NC}"
        [[ "$TELEGRAM_ENABLED" -eq 1 ]] && tg_txt="${GREEN}ACTIVADO${NC}"
        local mail_txt="${RED}DESACTIVADO${NC}"
        [[ "$EMAIL_ENABLED" -eq 1 ]] && mail_txt="${GREEN}ACTIVADO${NC}"

        local target_display="${NOTIFICATION_TARGET:-'(no configurado)'}"

        echo -e " 📱 Telegram:  $tg_txt | Chat ID: ${TELEGRAM_CHAT_ID:-'(no configurado)'}"
        echo -e " 📧 Proxmox:   $mail_txt | Destino: ${BOLD}$target_display${NC} [Modo: $EMAIL_NOTIFICATION_TYPE]"
        ui_hr
        echo -e "  ${YELLOW}1)${NC} 🔑 Configurar Telegram (Token y Chat ID)"
        echo -e "  ${YELLOW}2)${NC} 🔔 Enviar mensaje de prueba a Telegram"
        echo -e "  ${YELLOW}3)${NC} 🔁 Activar / Desactivar Telegram"
        echo -e "  ${YELLOW}4)${NC} 🎯 Seleccionar Destino de Proxmox (Gmail-Alertas, mail-to-root...)"
        echo -e "  ${YELLOW}5)${NC} ⚙️  Cambiar modo de aviso (failure: solo error | always: siempre)"
        echo -e "  ${YELLOW}6)${NC} 🔕 Activar / Desactivar Notificaciones de Proxmox"
        echo -e "  ${YELLOW}0)${NC} ↩️  Volver al menú principal"
        ui_hr
        read -rp "👉 Elige una opción [0-6]: " notif_opt

        case "$notif_opt" in
            0|"") break ;;
            1)
                echo
                read -rp "Pega tu Bot Token de Telegram: " new_t
                new_t="$(echo "$new_t" | tr -d ' ')"
                [[ -n "$new_t" ]] && TELEGRAM_BOT_TOKEN="$new_t"
                read -rp "Pega tu Chat ID de Telegram: " new_c
                new_c="$(echo "$new_c" | tr -d ' ')"
                [[ -n "$new_c" ]] && TELEGRAM_CHAT_ID="$new_c"
                TELEGRAM_ENABLED=1
                save_config
                echo -e "${GREEN}✓ Configuración de Telegram guardada.${NC}"
                sleep 1.5
                ;;
            2)
                echo "Enviando mensaje de prueba a Telegram..."
                test_msg="🔔 <b>Test de Notificación - Proxmox VE</b>%0A%0AConexión con <b>$(hostname)</b> verificada."
                send_telegram_message "$test_msg"
                echo -e "${GREEN}✓ Mensaje solicitado a Telegram.${NC}"
                sleep 1.5
                ;;
            3)
                if [[ "$TELEGRAM_ENABLED" -eq 1 ]]; then
                    TELEGRAM_ENABLED=0
                else
                    TELEGRAM_ENABLED=1
                fi
                save_config
                ;;
            4)
                select_proxmox_notification_target
                ;;
            5)
                if [[ "$EMAIL_NOTIFICATION_TYPE" == "failure" ]]; then
                    EMAIL_NOTIFICATION_TYPE="always"
                else
                    EMAIL_NOTIFICATION_TYPE="failure"
                fi
                save_config
                ;;
            6)
                if [[ "$EMAIL_ENABLED" -eq 1 ]]; then
                    EMAIL_ENABLED=0
                else
                    EMAIL_ENABLED=1
                fi
                save_config
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# MENÚ: Programación Automática de Backups en Cron
# ─────────────────────────────────────────────────────────────────────────────
CRON_TAG="# PROXMOX-USB-BACKUP-AUTO"

get_cron_entry() {
    local cline
    cline="$(crontab -l 2>/dev/null | grep -F "$CRON_TAG" -A 1 | grep -v -F "$CRON_TAG" | head -n 1 || true)"
    echo "$cline"
}

# Elimina de crontab SOLO la tarea gestionada por este script: la línea CRON_TAG y la orden que la sigue.
# Las demás entradas (aunque llamen a otros backup.sh) no se tocan.
# Con un argumento, lo añade como nueva entrada (precedida de CRON_TAG) tras la limpieza.
replace_cron_entry() {
    local new_line="${1:-}"
    local tmp_cron
    tmp_cron="$(mktemp)"
    crontab -l 2>/dev/null | awk -v tag="$CRON_TAG" '
        skip { skip = 0; if ($0 ~ /backup(\.sh|-proxmox-usb\.sh)/) next }
        index($0, tag) { skip = 1; next }
        { print }
    ' > "$tmp_cron" || true
    if [[ -n "$new_line" ]]; then
        echo "$CRON_TAG" >> "$tmp_cron"
        echo "$new_line" >> "$tmp_cron"
    fi
    crontab "$tmp_cron"
    rm -f "$tmp_cron"
}

# Orden de cron gestionada: la salida completa se añade a CRON_LOG_FILE (antes iba a /dev/null y un fallo
# temprano, p. ej. USB no conectado, no dejaba rastro ni aviso)
build_cron_command() {
    local cron_exp="$1" script_bin="$2"
    printf '%s %q --all -y >>%q 2>&1' "$cron_exp" "$script_bin" "$CRON_LOG_FILE"
}

# Actualiza la tarea de cron creada por versiones anteriores (salida a /dev/null) al formato actual,
# conservando su horario y la ruta del script. No hace nada si no hay tarea o ya está actualizada.
upgrade_legacy_cron_entry() {
    command -v crontab >/dev/null 2>&1 || return 0
    local cline
    cline="$(get_cron_entry)"
    [[ -n "$cline" && "$cline" == *" --all -y >/dev/null 2>&1" ]] || return 0
    local cron_exp script_part script_bin
    cron_exp="$(awk '{print $1, $2, $3, $4, $5}' <<< "$cline")"
    script_part="${cline#"$cron_exp" }"
    script_part="${script_part% --all -y >/dev/null 2>&1}"
    # La ruta se escribió con %q: se recupera sin evaluarla si no lleva escapes; si los lleva, se usa la actual
    if [[ "$script_part" == *\\* ]]; then
        script_bin="$(realpath "$0" 2>/dev/null || echo "$0")"
    else
        script_bin="$script_part"
    fi
    replace_cron_entry "$(build_cron_command "$cron_exp" "$script_bin")" 2>/dev/null || return 0
    log_info "Tarea de cron actualizada: la salida se guarda ahora en $CRON_LOG_FILE (antes se descartaba)."
    return 0
}

# Evita que CRON_LOG_FILE crezca sin límite: si supera CRON_LOG_MAX_BYTES conserva las últimas 5000 líneas.
# Se reescribe en el mismo fichero (no se reemplaza) porque cron puede tenerlo abierto en modo append.
rotate_cron_log() {
    [[ -f "$CRON_LOG_FILE" ]] || return 0
    local size
    size="$(stat -c %s "$CRON_LOG_FILE" 2>/dev/null || echo 0)"
    (( size > CRON_LOG_MAX_BYTES )) || return 0
    local tmp
    tmp="$(mktemp)" || return 0
    tail -n 5000 "$CRON_LOG_FILE" > "$tmp" 2>/dev/null && cat "$tmp" > "$CRON_LOG_FILE" 2>/dev/null
    rm -f "$tmp"
    return 0
}

format_cron_human() {
    local cline="$1"
    [[ -z "$cline" ]] && { echo "Desactivado"; return; }

    local c_min c_hour c_dom c_mon c_dow rest
    read -r c_min c_hour c_dom c_mon c_dow rest <<< "$cline"

    local d_name="Domingo"
    case "$c_dow" in
        0|7) d_name="Domingo" ;;
        1) d_name="Lunes" ;;
        2) d_name="Martes" ;;
        3) d_name="Miércoles" ;;
        4) d_name="Jueves" ;;
        5) d_name="Viernes" ;;
        6) d_name="Sábado" ;;
    esac

    local time_str
    time_str="$(printf "%02d:%02d" "${c_hour#0}" "${c_min#0}" 2>/dev/null || echo "$c_hour:$c_min")"

    if [[ "$c_dom" == "*" && "$c_mon" == "*" && "$c_dow" == "*" ]]; then
        echo "Diario a las $time_str (expresión: $c_min $c_hour * * *)"
    elif [[ "$c_dom" == "*" && "$c_mon" == "*" && "$c_dow" != "*" ]]; then
        echo "Semanal los ${d_name}s a las $time_str (expresión: $c_min $c_hour * * $c_dow)"
    elif [[ "$c_dom" != "*" && "$c_mon" == "*" && "$c_dow" == "*" ]]; then
        echo "Mensual el día $c_dom a las $time_str (expresión: $c_min $c_hour $c_dom * *)"
    else
        echo "Personalizado ($c_min $c_hour $c_dom $c_mon $c_dow)"
    fi
}

menu_cron_schedule() {
    local script_bin
    script_bin="$(readlink -f "${BASH_SOURCE[0]}")"
    [[ -z "$script_bin" ]] && script_bin="$SCRIPT_DIR/backup.sh"

    while true; do
        ui_header "📅 PROGRAMACIÓN AUTOMÁTICA DE BACKUPS (CRONTAB)"

        local current_job
        current_job="$(get_cron_entry)"
        local status_str="${RED}DESACTIVADO${NC}"
        local schedule_desc="Ninguno"

        if [[ -n "$current_job" ]]; then
            status_str="${GREEN}ACTIVADO${NC}"
            schedule_desc="$(format_cron_human "$current_job")"
        fi

        echo -e " 📅 Estado Cron:   $status_str"
        echo -e " ⏰ Programación:  ${BOLD}$schedule_desc${NC}"
        echo -e " 📜 Script a usar: $script_bin --all -y"
        ui_hr
        echo -e " ${YELLOW}1)${NC} 🗓️  Programar ${BOLD}Semanal${NC} (Elegir día y hora - RECOMENDADO)"
        echo -e " ${YELLOW}2)${NC} 📆 Programar ${BOLD}Diario${NC} (Todos los días a una hora fija)"
        echo -e " ${YELLOW}3)${NC} 📅 Programar ${BOLD}Mensual${NC} (El primer día de cada mes)"
        echo -e " ${YELLOW}4)${NC} ✏️  Introducir expresión personalizada de Cron"
        echo -e " ${YELLOW}5)${NC} 🗑️  ${RED}Eliminar / Desactivar tarea programada de cron${NC}"
        echo -e " ${YELLOW}0)${NC} ↩️  Volver al menú principal"
        ui_hr
        read -rp "👉 Elige una opción [0-5]: " cron_opt

        local new_cron_exp=""
        case "$cron_opt" in
            0|"") break ;;
            1)
                echo -e "\n${BOLD}Configuración de Backup Semanal:${NC}"
                echo "Días de la semana: 0=Domingo, 1=Lunes, 2=Martes, 3=Miércoles, 4=Jueves, 5=Viernes, 6=Sábado"
                read -rp "Día de la semana [0-6] (Por defecto 0: Domingo): " in_dow
                in_dow="${in_dow:-0}"
                [[ "$in_dow" =~ ^[0-7]$ ]] || in_dow=0

                read -rp "Hora de ejecución [0-23] (Por defecto 2 = 02:00 AM): " in_hour
                in_hour="${in_hour:-2}"
                [[ "$in_hour" =~ ^[0-9]+$ && "$in_hour" -ge 0 && "$in_hour" -le 23 ]] || in_hour=2

                read -rp "Minuto [0-59] (Por defecto 0): " in_min
                in_min="${in_min:-0}"
                [[ "$in_min" =~ ^[0-9]+$ && "$in_min" -ge 0 && "$in_min" -le 59 ]] || in_min=0

                new_cron_exp="$in_min $in_hour * * $in_dow"
                ;;
            2)
                echo -e "\n${BOLD}Configuración de Backup Diario:${NC}"
                read -rp "Hora de ejecución [0-23] (Por defecto 3 = 03:00 AM): " in_hour
                in_hour="${in_hour:-3}"
                [[ "$in_hour" =~ ^[0-9]+$ && "$in_hour" -ge 0 && "$in_hour" -le 23 ]] || in_hour=3

                read -rp "Minuto [0-59] (Por defecto 0): " in_min
                in_min="${in_min:-0}"
                [[ "$in_min" =~ ^[0-9]+$ && "$in_min" -ge 0 && "$in_min" -le 59 ]] || in_min=0

                new_cron_exp="$in_min $in_hour * * *"
                ;;
            3)
                echo -e "\n${BOLD}Configuración de Backup Mensual:${NC}"
                read -rp "Día del mes [1-28] (Por defecto 1): " in_dom
                in_dom="${in_dom:-1}"
                [[ "$in_dom" =~ ^[0-9]+$ && "$in_dom" -ge 1 && "$in_dom" -le 28 ]] || in_dom=1

                read -rp "Hora de ejecución [0-23] (Por defecto 2 = 02:00 AM): " in_hour
                in_hour="${in_hour:-2}"
                [[ "$in_hour" =~ ^[0-9]+$ && "$in_hour" -ge 0 && "$in_hour" -le 23 ]] || in_hour=2

                new_cron_exp="0 $in_hour $in_dom * *"
                ;;
            4)
                echo -e "\n${BOLD}Introduce los 5 campos de cron (ej: 0 2 * * 0):${NC}"
                read -rp "Expresión cron: " new_cron_exp
                new_cron_exp="$(echo "$new_cron_exp" | xargs)"
                local field_count
                field_count="$(echo "$new_cron_exp" | wc -w)"
                if [[ "$field_count" -ne 5 ]]; then
                    echo -e "${RED}ERROR: La expresión cron debe contener exactamente 5 campos.${NC}"
                    sleep 2
                    continue
                fi
                ;;
            5)
                replace_cron_entry
                echo -e "\n${GREEN}✓ Tarea programada eliminada de crontab con éxito.${NC}"
                sleep 1.5
                continue
                ;;
            *)
                continue
                ;;
        esac

        if [[ -n "$new_cron_exp" ]]; then
            # Ruta del script entrecomillada (%q) por si contiene espacios u otros caracteres especiales
            replace_cron_entry "$(build_cron_command "$new_cron_exp" "$script_bin")"

            echo -e "\n${GREEN}✓ ¡Tarea programada guardada con éxito en crontab!${NC}"
            echo -e "Horario configurado: ${BOLD}$(format_cron_human "$new_cron_exp")${NC}"
            sleep 2
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. MENÚ: Gestor de Logs (En vivo, errores, vaciado)
# ─────────────────────────────────────────────────────────────────────────────
menu_manage_logs() {
    while true; do
        ui_header "📜 GESTOR DE REGISTROS (LOGS)"
        echo -e "Archivo de log local: ${BOLD}$HOST_LOG_FILE${NC}"
        local lsz="0 KB"
        [[ -f "$HOST_LOG_FILE" ]] && lsz="$(du -h "$HOST_LOG_FILE" | awk '{print $1}')"
        echo -e "Tamaño actual del log: ${GREEN}$lsz${NC}"
        ui_hr
        echo -e "  ${YELLOW}1)${NC} 📜 Ver log en vivo en tiempo real (tail -f)"
        echo -e "  ${YELLOW}2)${NC} 🔍 Ver las últimas 50 líneas"
        echo -e "  ${YELLOW}3)${NC} ⚠️  Ver solo líneas con ERRORES o ADVERTENCIAS"
        echo -e "  ${YELLOW}4)${NC} 🧹 Vaciar el archivo de log local"
        echo -e "  ${YELLOW}5)${NC} 🛑 Detener proceso de backup activo en segundo plano"
        echo -e "  ${YELLOW}0)${NC} 🚪 Volver al menú principal"
        ui_hr
        read -rp "👉 Elige una opción [0-5]: " log_opt

        case "$log_opt" in
            0|"") break ;;
            1)
                ui_header "📜 LOG EN VIVO (Pulsa Ctrl + C para volver)"
                touch "$HOST_LOG_FILE" 2>/dev/null || true
                tail -n 30 -f "$HOST_LOG_FILE" || true
                ;;
            2)
                ui_header "🔍 ÚLTIMAS 50 LÍNEAS DE $HOST_LOG_FILE"
                tail -n 50 "$HOST_LOG_FILE" 2>/dev/null || echo "El archivo está vacío."
                pause_prompt
                ;;
            3)
                ui_header "⚠️ INCIDENCIAS Y ERRORES EN $HOST_LOG_FILE"
                grep -Ei 'error|failed|advertencia|warning' "$HOST_LOG_FILE" 2>/dev/null || echo "No se encontraron errores."
                pause_prompt
                ;;
            4)
                if ask_yes_no "¿Estás seguro de vaciar el log local?" "n"; then
                    : > "$HOST_LOG_FILE" 2>/dev/null || true
                    echo -e "${GREEN}✓ Log vaciado con éxito.${NC}"
                    sleep 1
                fi
                ;;
            5)
                stop_running_backup
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 7.5. RENDIMIENTO (ZSTD, BWLIMIT) Y LISTA NEGRA DE MÁQUINAS
# ─────────────────────────────────────────────────────────────────────────────
menu_performance_and_blacklist() {
    load_config
    while true; do
        ui_header "⚡ RETENCIÓN, RENDIMIENTO (ZSTD/I-O) Y LISTA NEGRA DE MÁQUINAS"

        local z_str="Automático de vzdump"
        [[ "$ZSTD_THREADS" -gt 0 ]] && z_str="$ZSTD_THREADS hilos"

        local b_str="Sin límite (máxima velocidad I/O)"
        if [[ "$BWLIMIT" -gt 0 ]]; then
            local mb_val=$((BWLIMIT / 1024))
            b_str="$BWLIMIT KiB/s (~${mb_val} MiB/s)"
        fi

        local bl_str="Ninguna (se respaldan todas las detectadas)"
        [[ -n "$BLACKLIST_VMS" ]] && bl_str="$BLACKLIST_VMS"

        local num_cpus
        num_cpus="$(nproc 2>/dev/null || echo "4")"

        echo -e " 📦 ${BOLD}Política de Retención:${NC} Conservar últimas ${BOLD}$KEEP_LAST${NC} copias completas"
        echo -e " 🚀 ${BOLD}Hilos compresión ZSTD:${NC} $z_str (CPUs detectadas: $num_cpus)"
        echo -e " ⚡ ${BOLD}Límite ancho de banda I/O:${NC} $b_str"
        echo -e " 🚫 ${BOLD}Lista Negra (Exclusiones fijas):${NC} $bl_str"
        ui_hr
        echo -e "  ${YELLOW}1)${NC} 📦 Cambiar política de retención (Número de copias a conservar)"
        echo -e "  ${YELLOW}2)${NC} ⚙️  Ajustar hilos de compresión ZSTD (--zstd)"
        echo -e "  ${YELLOW}3)${NC} ⚡ Ajustar límite de ancho de banda I/O (--bwlimit)"
        echo -e "  ${YELLOW}4)${NC} 🚫 Administrar lista negra de VMs/LXCs (Excluir permanentemente)"
        echo -e "  ${YELLOW}5)${NC} 🔄 Restablecer a valores recomendados (Retención: 3, ZSTD: Auto, I/O: 70000 KiB/s)"
        echo -e "  ${YELLOW}0)${NC} 🚪 Guardar y volver al menú principal"
        ui_hr
        read -rp "👉 Elige una opción [0-5]: " p_opt

        case "$p_opt" in
            0|"")
                save_config
                break
                ;;
            1)
                echo -e "\n${BOLD}Ajuste de Política de Retención Automática (KEEP_LAST)${NC}"
                echo "Define cuántas sesiones completas de backup se conservarán en el disco USB."
                echo "Al superarse este número, el script purga automáticamente las copias más antiguas."
                echo -e "Valor actual: ${BOLD}$KEEP_LAST${NC} copias."
                read -rp "Introduce nuevo número de copias a conservar [mínimo 1]: " new_k
                if [[ "$new_k" =~ ^[0-9]+$ ]] && (( new_k >= 1 )); then
                    KEEP_LAST="$new_k"
                    save_config
                    echo -e "${GREEN}✓ Política de retención actualizada a $KEEP_LAST copias.${NC}"
                else
                    echo -e "${RED}Valor no válido. Debe ser un número entero mayor o igual a 1.${NC}"
                fi
                sleep 1.5
                ;;
            2)
                echo -e "\n${BOLD}Ajuste de Hilos de Compresión ZSTD${NC}"
                echo "Define cuántos hilos de CPU puede usar zstd durante vzdump."
                echo "  • 0 = Valor por defecto de Proxmox (automático)."
                echo "  • 1 a $num_cpus = Número específico de hilos."
                read -rp "Introduce número de hilos [0-$num_cpus]: " in_threads
                if [[ "$in_threads" =~ ^[0-9]+$ ]] && (( in_threads <= num_cpus * 2 )); then
                    ZSTD_THREADS="$in_threads"
                    save_config
                    echo -e "${GREEN}✓ Hilos de compresión configurados en: $ZSTD_THREADS${NC}"
                else
                    echo -e "${RED}Valor no válido.${NC}"
                fi
                sleep 1
                ;;
            3)
                echo -e "\n${BOLD}Ajuste de Límite de Ancho de Banda I/O (bwlimit)${NC}"
                echo "Limita la velocidad de lectura/escritura para no saturar discos USB ni provocar errores E/S -5."
                echo "  • 0 = Sin límite (máxima velocidad posible)."
                echo "  • 70000 = ~70 MiB/s (Recomendado para discos USB externos)"
                read -rp "Introduce límite en KiB/s [0 para desactivar]: " in_bw
                if [[ "$in_bw" =~ ^[0-9]+$ ]]; then
                    BWLIMIT="$in_bw"
                    save_config
                    echo -e "${GREEN}✓ Límite I/O configurado en: $BWLIMIT KiB/s${NC}"
                else
                    echo -e "${RED}Valor no válido.${NC}"
                fi
                sleep 1
                ;;
            4)
                discover_guests
                echo -e "\n${BOLD}Gestión de Lista Negra de VMs y Contenedores${NC}"
                echo "Las máquinas en esta lista se ignorarán SIEMPRE en backups automáticos y --all."
                echo "Lista actual: [${BLACKLIST_VMS:-Ninguna}]"
                echo
                echo "Máquinas disponibles en el nodo:"
                for gid in "${ALL_GUEST_IDS[@]}"; do
                    local mark="[ ]"
                    if [[ ",$BLACKLIST_VMS," == *",$gid,"* ]]; then
                        mark="${RED}[EXCLUIDA]${NC}"
                    else
                        mark="${GREEN}[INCLUIDA]${NC}"
                    fi
                    echo -e "  $mark ID $gid - ${GUEST_TYPES[$gid]} ${GUEST_NAMES[$gid]}"
                done
                echo
                echo "Escribe los IDs separados por comas que deseas excluir (ej: 105,106),"
                echo "o presiona [Enter] sin escribir nada para vaciar la lista negra:"
                read -rp "IDs a excluir: " in_bl
                in_bl="$(echo "$in_bl" | tr -d ' ')"
                BLACKLIST_VMS="$in_bl"
                save_config
                echo -e "${GREEN}✓ Lista negra actualizada: [${BLACKLIST_VMS:-Vacía}]${NC}"
                sleep 1.5
                ;;
            5)
                KEEP_LAST=3
                ZSTD_THREADS=0
                BWLIMIT=70000
                BLACKLIST_VMS=""
                save_config
                echo -e "${GREEN}✓ Retención (3 copias), ZSTD (Auto), I/O (70000 KiB/s) y exclusiones restablecidos.${NC}"
                sleep 1.5
                ;;
            *)
                echo "Opción no válida."
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 7.6. CENTRO DE AYUDA Y GUÍA TÉCNICA COMPLETA
# ─────────────────────────────────────────────────────────────────────────────
menu_help() {
    while true; do
        ui_header "CENTRO DE AYUDA Y GUÍA TÉCNICA PROXMOX BACKUP"
        echo -e "  ${YELLOW}1)${NC} 🚀 ${BOLD}Funcionamiento General y Flujo de Copia${NC}"
        echo -e "  ${YELLOW}2)${NC} 🔌 ${BOLD}Discos Passthrough / Mountpoints y 'backup=0'${NC}"
        echo -e "  ${YELLOW}3)${NC} 💽 ${BOLD}Sistemas de Archivos USB: FAT32 (Peligro 4GB) vs ext4 / exfat${NC}"
        echo -e "  ${YELLOW}4)${NC} 🛡️  ${BOLD}Comprobación de Integridad de Copias (zstd -t y SHA-256)${NC}"
        echo -e "  ${YELLOW}5)${NC} 🔄 ${BOLD}Procedimiento de Restauración (VMs, LXC y Host)${NC}"
        echo -e "  ${YELLOW}6)${NC} 📅 ${BOLD}Automatización con Cron y Parámetros CLI (--all, -y, --dry-run)${NC}"
        echo -e "  ${YELLOW}7)${NC} ⚡ ${BOLD}Rendimiento, Bloqueos Residuales (qm unlock) y Notificaciones${NC}"
        echo -e "  ${YELLOW}8)${NC} 📖 ${BOLD}Ver Documentación Completa en Pantalla${NC}"
        echo -e "  ${YELLOW}0)${NC} 🚪 ${BOLD}Volver al Menú Principal${NC}"
        ui_hr "-" "$CYAN"
        read -rp "👉 Elige un tema de ayuda [0-8]: " h_opt

        case "$h_opt" in
            0|q|Q) break ;;
            1)
                ui_header "1. FUNCIONAMIENTO GENERAL Y FLUJO DE COPIA"
                cat <<'EOF'
Este script automatiza el respaldo íntegro de un nodo Proxmox VE directamente a un
disco duro externo o pendrive USB, sin requerir un servidor Proxmox Backup Server (PBS).

Flujo de ejecución:
1. Detección del USB: Identifica el disco por su UUID único (/dev/disk/by-uuid/<UUID>),
   evitando problemas si la letra del dispositivo cambia (/dev/sdb, /dev/sdc, etc.).
2. Montaje Seguro: Se monta en /media/backup. Al terminar (o si se cancela), se
   desmonta de forma limpia y garantizada mediante un hook 'trap EXIT'.
3. Copia del Host Proxmox: Comprime en proxmox-host-config-<STAMP>.tar.gz archivos críticos:
   /etc/pve, /etc/hosts, /etc/network/interfaces, /etc/fstab, repositorios APT, etc.
4. Respaldo de VMs y Contenedores LXC: Emplea la herramienta nativa 'vzdump' en modo
   'snapshot' con compresión ultrarrápida 'zstd'.
5. Integridad SHA-256: Actualiza y sincroniza SHA256SUMS con los hashes de cada archivo.
6. Retención (KEEP_LAST): Mantiene las últimas N copias por invitado y purga las antiguas.
7. Notificación: Envía el informe detallado por Telegram y Notificaciones de Proxmox VE.
EOF
                pause_prompt
                ;;
            2)
                ui_header "2. DISCOS PASSTHROUGH / MOUNTPOINTS Y 'backup=0'"
                cat <<'EOF'
¿Qué es un disco Passthrough o Mountpoint secundario?
En Proxmox VE, es común asignar discos duros físicos enteros a una máquina virtual
(/dev/disk/by-id/ata-WDC...) o puntos de montaje adicionales (mp0, mp1...) a contenedores LXC.

El Problema con vzdump:
Por defecto, Proxmox VE intenta respaldar TODOS los discos asignados a una VM,
incluidos los discos passthrough mecánicos de varios Terabytes.
Si tienes un disco USB de 1 TB y una VM tiene 16 TB en discos passthrough, el backup
fallará inevitablemente por falta de espacio ("No space left on device").

La Solución:
En el archivo de configuración (/etc/pve/qemu-server/<vmid>.conf o /etc/pve/lxc/<ctid>.conf),
se puede controlar cada disco/mountpoint mediante ',backup=0' (excluir) o ',backup=1' (incluir).
Ejemplo:
  scsi1: /dev/disk/by-id/ata-WDC...,backup=0
  mp0: /mnt/datos,mp=/datos,backup=0

El script detecta esto automáticamente:
- La opción 4 (Calculadora) desglosa qué discos se copiarán y cuáles se omitirán.
- La opción 7 del menú permite activar o desactivar backup=0 en VMs y LXCs con un clic.
- Durante el backup, si detecta passthrough sin backup=0, te avisa y ofrece excluirlo.
EOF
                pause_prompt
                ;;
            3)
                ui_header "3. SISTEMAS DE ARCHIVOS USB: PELIGRO DE FAT32 vs EXT4 / EXFAT"
                cat <<'EOF'
¿Por qué FAT32 (vfat) es peligroso para backups de Proxmox?
El sistema de archivos FAT32 tiene una limitación técnica insalvable:
EL TAMAÑO MÁXIMO DE UN ARCHIVO INDIVIDUAL ES DE 4 GiB (4.294.967.295 bytes).

Dado que un backup de una VM comprimido con zstd (.vma.zst) suele ocupar entre
10 GiB y más de 100 GiB, tan pronto como vzdump escribe 4 GiB en una partición FAT32,
el kernel de Linux genera un error de escritura ("Write error / File too large")
y el proceso de backup se aborta.

Sistemas de archivos recomendados:
1. ext4 (Recomendado para Linux/Proxmox):
   - Soporte nativo absoluto, máxima velocidad, journaling y sin límite práctico de tamaño.
2. exfat:
   - Compatible si deseas conectar el disco USB directamente a ordenadores con Windows o Mac.

El script incluye un formateador seguro dentro de la opción 5 (Centro de Almacenamiento USB)
para convertir tu partición a ext4 o exfat con doble confirmación.
EOF
                pause_prompt
                ;;
            4)
                ui_header "4. COMPROBACIÓN DE INTEGRIDAD DE COPIAS"
                cat <<'EOF'
Un backup solo es válido si se puede leer sin errores.
El script proporciona dos métodos de verificación rigurosos sin necesidad de restaurar:

1. Verificación de compresión Zstandard (zstd -t):
   Prueba el flujo de compresión completo de los archivos .vma.zst y .tar.zst
   comprobando que cada bloque de datos y checksum interno sea perfecto.

2. Verificación de integridad criptográfica SHA-256:
   Cada vez que finaliza un backup, se actualiza el archivo SHA256SUMS en la carpeta dump.
   El verificador compara el hash sha256 actual con el registrado en el momento del backup
   para certificar que ni un solo bit se ha corrompido.

Puedes ejecutar esta prueba desde la opción 6 (Explorar, Verificar Integridad y Borrar Copias)
escribiendo 't <Nº>' para un archivo o 't all' para verificar todo el repositorio.
EOF
                pause_prompt
                ;;
            5)
                ui_header "5. PROCEDIMIENTO DE RESTAURACIÓN"
                cat <<'EOF'
Restaurar Máquinas Virtuales QEMU:
- A través del script: Opción 3 del Menú Principal.
- Vía terminal (qmrestore):
  qmrestore /media/backup/dump/vzdump-qemu-<ID>-<STAMP>.vma.zst <NUEVO_ID_O_MISMO> --storage local-lvm

Restaurar Contenedores LXC:
- A través del script: Opción 3 del Menú Principal.
- Vía terminal (pct restore):
  pct restore <NUEVO_ID> /media/backup/dump/vzdump-lxc-<ID>-<STAMP>.tar.zst --storage local-lvm

Restaurar Configuración del Host Proxmox:
- El archivo 'proxmox-host-config-<STAMP>.tar.gz' contiene la configuración del sistema.
- Se recomienda inspeccionar su contenido antes de sobreescribir:
  tar -ztvf proxmox-host-config-<STAMP>.tar.gz
- Para extraer archivos específicos (ej: interfaces de red):
  tar -xzf proxmox-host-config-<STAMP>.tar.gz -C / etc/network/interfaces
EOF
                pause_prompt
                ;;
            6)
                ui_header "6. AUTOMATIZACIÓN CON CRON Y PARÁMETROS CLI"
                cat <<'EOF'
Uso mediante Menú:
La opción 8 del menú principal te permite programar la copia diaria o semanal
directamente en crontab con un asistente gráfico (ej: Diariamente a las 03:00 AM).

Uso mediante Terminal (Scripts, SSH o Nohup):
- Backup completo desatendido:
    ./backup.sh --all -y
- Simulación Dry-Run (sin escribir datos ni ejecutar vzdump):
    ./backup.sh --all -y --dry-run
- Ejecución en segundo plano persistente:
    ./backup.sh --all -y --bg
- Backup exclusivo de máquinas específicas:
    ./backup.sh --vms 100,104 -y
- Máquinas específicas incluyendo configuración del host:
    ./backup.sh --vms 100,104 --with-host -y
- Solo configuración del host:
    ./backup.sh --host-only -y
- Montar o desmontar manualmente:
    ./backup.sh --mount
    ./backup.sh --umount
- Consultar estado del Cron:
    ./backup.sh --cron-status
EOF
                pause_prompt
                ;;
            7)
                ui_header "7. RENDIMIENTO, BLOQUEOS RESIDUALES Y ALERTAS"
                cat <<'EOF'
Bloqueos Residuales (lock: backup):
Si un backup se interrumpió abruptamente (por ejemplo, corte de energía o desconexión
del USB), Proxmox bloquea la máquina virtual con 'lock: backup' impidiendo encenderla
o respaldarla.
-> Este script detecta y libera automáticamente estos bloqueos antes de iniciar.
-> Manualmente se libera con: qm unlock <VMID> o pct unlock <CTID>.

Optimización de Rendimiento (Opción 9):
- Hilos ZSTD (--zstd): Configura el paralelismo de compresión para aprovechar todos
  los núcleos de la CPU o limitar el impacto en las VMs activas.
- Límite I/O (--bwlimit): Evita saturar el bus USB o los discos de producción fijando
  un tope en KiB/s (ej: 70000 para ~70 MiB/s).
- Lista Negra: VMs de pruebas o desarrollo que no requieras respaldar nunca.

Notificaciones (Opción 11):
- Alertas inmediatas en Telegram con desglose de tamaño y tiempo por máquina.
- Integración nativa con los destinos de Notificaciones de Proxmox VE (--notification-target).
EOF
                pause_prompt
                ;;
            8)
                ui_header "MANUAL COMPLETO Y GUÍA TÉCNICA - PROXMOX USB BACKUP SUITE"
                cat <<'EOF'
1. ARQUITECTURA:
   - Respaldo atómico a disco USB externo mediante vzdump + tar + zstd.
   - Montaje dinámico por UUID para resiliencia ante reinicios y desconexiones.
   - Bloqueo exclusivo con flock ($SCRIPT_DIR/backup.lock) para evitar colisiones.
   - Desmontaje limpio garantizado con traps del sistema operativo.

2. SEGURIDAD Y PASSTHROUGH (QEMU + LXC):
   - Detección de discos passthrough (/dev/disk/by-id/...) en VMs y mountpoints (mpX) en LXC.
   - Adición automática de 'backup=0' para evitar saturar el almacenamiento de respaldo.

3. INTEGRIDAD Y VALIDACIÓN:
   - Verificación de descompresión Zstandard sin requerir espacio de restauración.
   - Comprobación y sincronización automática de sumas criptográficas SHA256SUMS.

4. AUTOMATIZACIÓN Y OPERACIÓN DESATENDIDA:
   - Integración nativa con cron del sistema.
   - Flags CLI completos (--all, -y, --dry-run, --vms, --mount, --umount, --cron-status).
   - Notificaciones ricas para Telegram y Notificaciones nativas de Proxmox VE.
EOF
                pause_prompt
                ;;
            *)
                echo "Opción no válida."
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. MENÚ Y MOTOR DE EJECUCIÓN DEL BACKUP (Primer Plano / Segundo Plano)
# ─────────────────────────────────────────────────────────────────────────────
# Orquestador del motor de backup: ejecuta las fases en orden (bloqueo, montaje, selección, passthrough,
# host, vzdump, verificación, retención, SHA-256, resumen y notificación). Cada fase es una función motor_*
# que comparte su estado mediante las globales ENGINE_*.
execute_backup_engine() {
    motor_reiniciar_estado
    motor_adquirir_bloqueo
    [[ "$ENGINE_LOCK_OK" -eq 1 ]] || return 0
    motor_montar_destino
    motor_seleccionar_elementos
    motor_filtrar_lista_negra
    motor_validar_seleccion
    motor_comprobar_passthrough
    motor_estimar_espacio
    motor_preparar_directorio

    if [[ "$CLI_DRY_RUN" -eq 1 ]]; then
        motor_mostrar_simulacion
        engine_finish
        return 0
    fi

    motor_iniciar_log_sesion
    motor_respaldar_host
    motor_respaldar_guests
    motor_verificar_copias_nuevas
    motor_aplicar_retencion
    motor_generar_sumas_sha256
    motor_mostrar_resumen
    motor_notificar_resultado

    log_info "Sesión finalizada."
    engine_finish
    # El resultado queda en FAILED (no se devuelve como código: el llamador no debe invocar el motor con ||/if,
    # porque eso desactivaría set -e dentro de él)
    return 0
}

# Fase 0: carga la configuración y reinicia el estado de ejecuciones previas
# (el menú puede lanzar varias copias en la misma sesión)
motor_reiniciar_estado() {
    load_config
    START_TIME=$SECONDS
    FAILED=0
    ALERT_SENT=0
    LOG_FILE=""
    ENGINE_LOCK_OK=0
    ENGINE_FINISHED=0
    ENGINE_FREE_GB=0
    ENGINE_EST_GB=0
    ENGINE_SELECTED=()
    ENGINE_DO_HOST=1
    ENGINE_STAMP=""
    ENGINE_NEW_ARCHIVES=()
    ENGINE_SUMMARY_REPORT=()
    ENGINE_VERIFY_FAILED=0
    ENGINE_PERF_OPTS=()
    ENGINE_NOTIF_TARGET_OK=0
    ENGINE_TOTAL_SZ=""
    ENGINE_FINAL_FREE_GB=0
    ENGINE_TOTAL_ELAPSED=0
    return 0
}

# Fase 1: protección de concurrencia con flock sobre el fd 200 (se abre en modo append para no borrar el PID
# de otra instancia). Deja ENGINE_LOCK_OK=1 si se obtiene; si no, en el menú marca FAILED=1 y en CLI sale con 1.
motor_adquirir_bloqueo() {
    exec 200>>"$LOCK_FILE"
    if ! flock -n 200; then
        exec 200>&-
        echo -e "\n${RED}=====================================================================${NC}"
        echo -e "${RED}${BOLD}ERROR: Ya existe otra instancia de este script ejecutándose.${NC}"
        echo -e "${RED}=====================================================================${NC}"
        echo "Bloqueo activo en: $LOCK_FILE"
        log_err "No se inicia la copia: ya existe otra instancia en ejecución (bloqueo activo en $LOCK_FILE)."
        if [[ "$MENU_MODE" -eq 1 ]]; then
            FAILED=1
            return 0
        fi
        send_notifications_alert "⚠️ <b>Backup Proxmox VE no iniciado</b>%0A%0A• <b>Host:</b> $(html_escape "$(hostname)")%0A• <b>Motivo:</b> ya hay otra copia en ejecución (bloqueo activo)."
        ALERT_SENT=1
        exit 1
    fi
    echo "$$" > "$LOCK_FILE" 2>/dev/null || true
    # A partir de aquí cualquier salida con error (set -e, señal...) avisa, libera el bloqueo y desmonta
    trap engine_exit_handler EXIT
    ENGINE_LOCK_OK=1
    return 0
}

# Fase 2: (re)monta el USB configurado, avisa si es FAT32 y comprueba el espacio libre mínimo (ENGINE_FREE_GB)
motor_montar_destino() {
    # Si el USB configurado ya estaba montado (p. ej. desde el menú), remontarlo limpio.
    # Nunca se fuerza (umount -l) ni se desmonta otro dispositivo que ocupe $MOUNTPOINT.
    if is_our_usb_mounted; then
        umount "$MOUNTPOINT" 2>/dev/null || true
    fi
    if ! mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        MOUNTED_BY_SCRIPT=0
    fi

    if ! mount_usb_device; then
        abort "No se pudo montar el disco USB con UUID: $USB_UUID. Conéctalo y verifica el dispositivo."
    fi

    # Detección y alerta sobre FAT32 (límite de 4 GiB)
    local rdev fstype
    rdev="$(readlink -f "/dev/disk/by-uuid/$USB_UUID" 2>/dev/null || true)"
    if [[ -n "$rdev" ]]; then
        fstype="$(blkid -s TYPE -o value "$rdev" 2>/dev/null || echo "")"
        if [[ "$fstype" =~ ^(vfat|fat32|msdos)$ ]]; then
            echo -e "\n${YELLOW}⚠️  ADVERTENCIA CRÍTICA: El USB está formateado en FAT32 ($fstype).${NC}"
            echo -e "${YELLOW}FAT32 no soporta archivos de más de 4 GiB. Los backups de VMs grandes fallarán.${NC}"
            echo -e "${YELLOW}Recomendación: Formatea el USB a ext4 o exfat desde el menú de Almacenamiento USB.${NC}\n"
            log_warn "Disco USB con sistema de archivos FAT32 ($fstype). Archivos >4 GiB fallarán."
        fi
    fi

    local free_kb
    free_kb="$(df -Pk "$MOUNTPOINT" | awk 'NR==2 {print $4}')"
    ENGINE_FREE_GB=$((free_kb / 1024 / 1024))
    (( ENGINE_FREE_GB >= MIN_FREE_GB )) || abort "Espacio insuficiente en USB: solo hay ${ENGINE_FREE_GB} GiB libres (Mínimo: ${MIN_FREE_GB} GiB)."
    return 0
}

# Fase 3: descubre VMs/LXCs y decide qué respaldar según la CLI (--host-only, --vms, --all) o, en su defecto,
# con la selección interactiva. Resultado en ENGINE_SELECTED y ENGINE_DO_HOST.
motor_seleccionar_elementos() {
    discover_guests
    ENGINE_SELECTED=()
    ENGINE_DO_HOST=1

    if [[ "$CLI_HOST_ONLY" -eq 1 ]]; then
        ENGINE_SELECTED=()
        ENGINE_DO_HOST=1
    elif [[ -n "$CLI_SELECTED_GUESTS" ]]; then
        IFS=',' read -ra REQ_IDS <<< "$CLI_SELECTED_GUESTS"
        local missing_ids=()
        for rid in "${REQ_IDS[@]}"; do
            rid="$(echo "$rid" | tr -d ' ')"
            [[ -z "$rid" ]] && continue
            if [[ -n "${GUEST_TYPES[$rid]:-}" ]]; then
                ENGINE_SELECTED+=("$rid")
            else
                missing_ids+=("$rid")
            fi
        done
        if [[ ${#missing_ids[@]} -gt 0 ]]; then
            abort "Los IDs indicados con --vms no existen en este nodo: ${missing_ids[*]}. Revisa 'qm list' y 'pct list'."
        fi
        if [[ "$CLI_INCLUDE_HOST" -eq 1 ]]; then
            ENGINE_DO_HOST=1
        else
            ENGINE_DO_HOST=0
        fi
    elif [[ "$CLI_ALL" -eq 1 ]]; then
        # 0 guests detectados con --all: distinguir un nodo vacío de un fallo de qm/pct (PATH, cluster...)
        if [[ ${#ALL_GUEST_IDS[@]} -eq 0 ]]; then
            if ! command -v qm >/dev/null 2>&1 || ! command -v pct >/dev/null 2>&1; then
                abort "No se encuentran los comandos qm/pct (PATH=$PATH). No se puede detectar ninguna VM/LXC."
            elif compgen -G "/etc/pve/qemu-server/*.conf" >/dev/null || compgen -G "/etc/pve/lxc/*.conf" >/dev/null; then
                abort "--all no ha detectado ninguna VM/LXC aunque existen configuraciones en /etc/pve. Revisa 'qm list' y 'pct list'."
            else
                log_warn "No hay VMs ni contenedores LXC en este nodo: solo se respaldará la configuración del host."
            fi
        fi
        ENGINE_SELECTED=("${ALL_GUEST_IDS[@]}")
        if [[ "$CLI_INCLUDE_HOST" -eq 0 ]]; then
            ENGINE_DO_HOST=0
        else
            ENGINE_DO_HOST=1
        fi
    else
        motor_seleccion_interactiva
    fi
    return 0
}

# Fase 3 (sin --all/--vms/--host-only): selección en pantalla; sin terminal (cron, nohup) no es posible
motor_seleccion_interactiva() {
    if [[ ! -t 0 ]]; then
        abort "Ejecución no interactiva sin selección de elementos: indica --all, --vms <ids> o --host-only."
    fi
    ui_header "🎯 SELECCIÓN DE ELEMENTOS A RESPALDAR"
    echo "Elementos detectados en este nodo Proxmox:"
    for gid in "${ALL_GUEST_IDS[@]}"; do
        local sz
        sz="$(estimate_guest_disk_gb "$gid")"
        echo -e "  • [ID $gid] ${GUEST_TYPES[$gid]} ${GUEST_NAMES[$gid]} (${GUEST_STATUS[$gid]}) ~${sz} GiB"
    done
    echo "  • [HOST  ] Configuración global del host Proxmox, red y hooks"
    echo
    echo " 1) 🌐 Respaldar TODOS los elementos (VMs + LXCs + Host)"
    echo " 2) 🎯 Seleccionar máquinas específicas por ID"
    echo " 3) 🖥️  Solo configuración del Host Proxmox"
    echo " 0) 🚪 Cancelar"
    read -rp "👉 Elige una opción [1-3, 0]: " sel_sub_opt
    case "$sel_sub_opt" in
        1)
            ENGINE_SELECTED=("${ALL_GUEST_IDS[@]}")
            ENGINE_DO_HOST=1
            ;;
        2)
            read -rp "Introduce IDs separados por comas (ej: 100,104): " raw_sub_ids
            IFS=',' read -ra REQ_SUB <<< "$raw_sub_ids"
            for rid in "${REQ_SUB[@]}"; do
                rid="$(echo "$rid" | tr -d ' ')"
                [[ -z "$rid" ]] && continue
                if [[ -n "${GUEST_TYPES[$rid]:-}" ]]; then
                    ENGINE_SELECTED+=("$rid")
                else
                    echo -e "${YELLOW}⚠️ El ID $rid no existe en este nodo: se ignora.${NC}"
                fi
            done
            if ask_yes_no "¿Incluir configuración del Host Proxmox?" "n"; then
                ENGINE_DO_HOST=1
            else
                ENGINE_DO_HOST=0
            fi
            ;;
        3)
            ENGINE_SELECTED=()
            ENGINE_DO_HOST=1
            ;;
        0|*)
            abort "Operación cancelada por el usuario."
            ;;
    esac
    return 0
}

# Fase 3.1: quita de ENGINE_SELECTED los IDs de la lista negra permanente (BLACKLIST_VMS)
motor_filtrar_lista_negra() {
    if [[ -n "$BLACKLIST_VMS" && ${#ENGINE_SELECTED[@]} -gt 0 ]]; then
        local bl_filtered=()
        local bl_omitted=()
        IFS=',' read -ra BL_ARR <<< "$BLACKLIST_VMS"
        for gid in "${ENGINE_SELECTED[@]}"; do
            local is_bl=0
            for b_id in "${BL_ARR[@]}"; do
                b_id="$(echo "$b_id" | tr -d ' ')"
                if [[ "$gid" == "$b_id" ]]; then
                    is_bl=1
                    break
                fi
            done
            if [[ "$is_bl" -eq 1 ]]; then
                bl_omitted+=("$gid")
            else
                bl_filtered+=("$gid")
            fi
        done
        if [[ ${#bl_omitted[@]} -gt 0 ]]; then
            echo -e "${YELLOW}🚫 Omitiendo elementos presentes en Lista Negra: ${bl_omitted[*]}${NC}"
            log_info "Omitiendo elementos en lista negra: ${bl_omitted[*]}"
            ENGINE_SELECTED=("${bl_filtered[@]}")
        fi
    fi
    return 0
}

# Fase 3.2: si tras la selección y la lista negra no queda nada (ni VMs/LXCs ni host), no hay copia que hacer:
# se aborta con error en vez de terminar con "ÉXITO" sin haber respaldado nada
motor_validar_seleccion() {
    if [[ ${#ENGINE_SELECTED[@]} -eq 0 && "$ENGINE_DO_HOST" -ne 1 ]]; then
        abort "No hay nada que respaldar: ninguna VM/LXC seleccionada (o todas están en la lista negra) y el host excluido."
    fi
    return 0
}

# Fase 4: avisa de discos passthrough sin backup=0 en lo seleccionado y, solo con confirmación interactiva,
# los marca con backup=0 (con -y o --dry-run nunca se modifica /etc/pve)
motor_comprobar_passthrough() {
    for gid in "${ENGINE_SELECTED[@]}"; do
        local conf_file="/etc/pve/qemu-server/${gid}.conf"
        [[ "${GUEST_TYPES[$gid]}" == "LXC" ]] && conf_file="/etc/pve/lxc/${gid}.conf"
        if [[ -f "$conf_file" ]]; then
            local pt_disks
            pt_disks="$(conf_passthrough_without_backup0 "$conf_file")"
            if [[ -n "$pt_disks" ]]; then
                echo -e "\n${YELLOW}⚠️ ADVERTENCIA: ${GUEST_TYPES[$gid]} $gid (${GUEST_NAMES[$gid]}) tiene discos passthrough directos sin 'backup=0':${NC}"
                echo "$pt_disks" | sed 's/^/    /'
                echo -e "${YELLOW}Si vzdump intenta copiar estos discos mecánicos, el USB se llenará y fallará.${NC}"
                if [[ "$CLI_YES" -eq 1 || "$CLI_DRY_RUN" -eq 1 ]]; then
                    # Modo desatendido o simulación: nunca se modifica /etc/pve sin confirmación expresa
                    log_warn "ID $gid tiene discos passthrough sin backup=0; no se modifica su configuración (-y / --dry-run). Usa el menú 'Gestionar Discos y Passthrough'."
                elif ask_yes_no "¿Deseas marcar automáticamente backup=0 en estos discos passthrough para continuar con seguridad?" "s"; then
                    while read -r dline; do
                        local d_key
                        d_key="$(echo "$dline" | cut -d':' -f1 | tr -d ' ')"
                        conf_disk_backup_off "$conf_file" "$d_key"
                    done <<< "$pt_disks"
                    echo -e "${GREEN}✓ Discos passthrough excluidos del backup de ID $gid.${NC}"
                fi
            fi
        fi
    done
    return 0
}

# Fase 4.1: estimación orientativa de espacio (ENGINE_EST_GB): tamaño de los discos SIN comprimir (zstd suele
# ocupar bastante menos), por eso solo se avisa; el corte duro sigue siendo MIN_FREE_GB
motor_estimar_espacio() {
    ENGINE_EST_GB=0
    for gid in "${ENGINE_SELECTED[@]}"; do
        ENGINE_EST_GB=$(( ENGINE_EST_GB + $(estimate_guest_disk_gb "$gid") ))
    done
    if (( ENGINE_EST_GB > ENGINE_FREE_GB )); then
        log_warn "Tamaño estimado de los discos a respaldar (~${ENGINE_EST_GB} GiB sin comprimir) superior al espacio libre en el USB (${ENGINE_FREE_GB} GiB). La copia podría no caber."
    fi
    return 0
}

# Fase 5: fija la marca de tiempo de la sesión (ENGINE_STAMP) y el directorio de respaldos nativo de Proxmox VE (RUN_DIR)
motor_preparar_directorio() {
    ENGINE_STAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
    RUN_DIR="$MOUNTPOINT/dump"
    mkdir -p "$RUN_DIR"
    return 0
}

# Fase 5 (--dry-run): muestra qué se copiaría y qué purgaría la retención, sin escribir ni borrar nada
motor_mostrar_simulacion() {
    echo -e "\n${YELLOW}${BOLD}🧪 MODO SIMULACIÓN (--dry-run): No se escribirán ni borrarán backups en el USB.${NC}"
    echo -e "  • Destino:         $RUN_DIR"
    echo -e "  • Espacio libre:   ${ENGINE_FREE_GB} GiB (estimación sin comprimir de lo seleccionado: ~${ENGINE_EST_GB} GiB)"
    echo -e "  • Incluir Host:    $([ "$ENGINE_DO_HOST" -eq 1 ] && echo "SÍ" || echo "NO")"
    echo -e "  • Máquinas a copiar (${#ENGINE_SELECTED[@]}): ${ENGINE_SELECTED[*]:-Ninguna}"
    echo -e "  • Retención:       Conservar últimas $KEEP_LAST copias"
    prune_old_backups "$RUN_DIR" "$KEEP_LAST" 1
    return 0
}

# Fase 6: crea el log de la sesión en el USB (LOG_FILE) y registra el inicio
motor_iniciar_log_sesion() {
    LOG_FILE="$RUN_DIR/backup-${ENGINE_STAMP}.log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    log_info "Inicio de la sesión de backup en $(hostname)."
    log_info "Destino nativo Proxmox: $RUN_DIR"
    log_info "Log local sincronizado en: $HOST_LOG_FILE"
    return 0
}

# Fase 7: archiva la configuración del host Proxmox (si ENGINE_DO_HOST=1) en proxmox-host-config-<fecha>.tar.gz
motor_respaldar_host() {
    [[ "$ENGINE_DO_HOST" -eq 1 ]] || return 0
    echo -e "\n${CYAN}─── [1/2] Respaldando Configuración del Host Proxmox ───${NC}"
    local h_start=$SECONDS
    local host_paths=(etc/pve etc/hosts etc/fstab etc/apt etc/kernel etc/default/grub etc/modprobe.d etc/modules etc/network/interfaces var/lib/vz/snippets)
    local valid_paths=()
    for hp in "${host_paths[@]}"; do
        [[ -e "/$hp" ]] && valid_paths+=("$hp")
    done

    local host_tar="$RUN_DIR/proxmox-host-config-${ENGINE_STAMP}.tar.gz"
    if tar -czf "$host_tar" -C / "${valid_paths[@]}" 2>>"$LOG_FILE"; then
        chmod 600 "$host_tar" 2>/dev/null || true
        ENGINE_NEW_ARCHIVES+=("$host_tar")
        local hsz
        hsz="$(du -sh "$host_tar" | awk '{print $1}')"
        local htime=$((SECONDS - h_start))
        log_info "Configuración del host archivada con éxito ($hsz en $(format_seconds "$htime"))."
        ENGINE_SUMMARY_REPORT+=("✓ [HOST] Configuración Proxmox | $hsz | $(format_seconds "$htime")")
    else
        log_err "Error al comprimir la configuración del host."
        ENGINE_SUMMARY_REPORT+=("✗ [HOST] Configuración Proxmox | ERROR | $(format_seconds $((SECONDS - h_start)))")
        FAILED=1
    fi
    return 0
}

# Fase 8: respalda con vzdump cada VM/LXC de ENGINE_SELECTED (opciones de rendimiento comunes a todas)
motor_respaldar_guests() {
    [[ ${#ENGINE_SELECTED[@]} -gt 0 ]] || return 0
    echo -e "\n${CYAN}─── [2/2] Respaldando VMs y Contenedores LXC con vzdump ───${NC}"
    local c_idx=0
    local total_g=${#ENGINE_SELECTED[@]}

    ENGINE_PERF_OPTS=()
    [[ "$ZSTD_THREADS" -gt 0 ]] && ENGINE_PERF_OPTS+=(--zstd "$ZSTD_THREADS")
    [[ "$BWLIMIT" -gt 0 ]] && ENGINE_PERF_OPTS+=(--bwlimit "$BWLIMIT")

    # Detectar si vzdump soporta --notification-target (Proxmox VE 8.1+)
    ENGINE_NOTIF_TARGET_OK=0
    if vzdump --help 2>&1 | grep -q -- '--notification-target'; then
        ENGINE_NOTIF_TARGET_OK=1
    fi

    for gid in "${ENGINE_SELECTED[@]}"; do
        ((++c_idx))
        motor_respaldar_guest "$gid" "$c_idx" "$total_g"
    done
    return 0
}

# Libera un 'lock: backup' huérfano de la VM/LXC <id> (<tipo>) antes de lanzar su vzdump
motor_liberar_bloqueo_residual() {
    local gid="$1" gtype="$2"
    if [[ "$gtype" == *"VM"* ]]; then
        if qm config "$gid" 2>/dev/null | grep -q "^lock:[[:space:]]*backup"; then
            echo -e "${YELLOW}⚠️ Aviso: La VM $gid tenía un bloqueo residual (lock: backup). Desbloqueando...${NC}"
            qm unlock "$gid" 2>/dev/null || true
            log_warn "Se liberó el bloqueo residual de la VM $gid."
        fi
    elif [[ "$gtype" == "LXC" ]]; then
        if pct config "$gid" 2>/dev/null | grep -q "^lock:[[:space:]]*backup"; then
            echo -e "${YELLOW}⚠️ Aviso: El LXC $gid tenía un bloqueo residual (lock: backup). Desbloqueando...${NC}"
            pct unlock "$gid" 2>/dev/null || true
            log_warn "Se liberó el bloqueo residual del contenedor $gid."
        fi
    fi
    return 0
}

# Fase 8 (un elemento): vzdump de <id> (posición <n> de <total>); registra el archivo en ENGINE_NEW_ARCHIVES,
# añade su línea al resumen y marca FAILED=1 si vzdump falla
motor_respaldar_guest() {
    local gid="$1" c_idx="$2" total_g="$3"
    local gname="${GUEST_NAMES[$gid]}"
    local gtype="${GUEST_TYPES[$gid]}"
    local gstart=$SECONDS

    echo -e "\n${BOLD}[$c_idx/$total_g] Respaldando $gtype $gid ($gname)...${NC}"
    log_info "Iniciando vzdump de $gtype $gid ($gname) modo snapshot zstd."

    motor_liberar_bloqueo_residual "$gid" "$gtype"

    # Opciones de notificación nativas de Proxmox VE
    local mail_opts=()
    if [[ "$EMAIL_ENABLED" -eq 1 ]]; then
        mail_opts=(--mailnotification "$EMAIL_NOTIFICATION_TYPE")
        if [[ "$ENGINE_NOTIF_TARGET_OK" -eq 1 && -n "$NOTIFICATION_TARGET" ]]; then
            mail_opts+=(--notification-target "$NOTIFICATION_TARGET")
        fi
    else
        mail_opts=(--mailnotification never)
    fi

    set +e
    vzdump "$gid" \
        --dumpdir "$RUN_DIR" \
        --mode snapshot \
        --compress zstd \
        "${ENGINE_PERF_OPTS[@]}" \
        "${mail_opts[@]}" 2>&1 | tee -a "$LOG_FILE" "$HOST_LOG_FILE"
    local v_status="${PIPESTATUS[0]}"
    set -e

    local gtime=$((SECONDS - gstart))
    local out_file
    out_file="$(find "$RUN_DIR" -maxdepth 1 \( -name "vzdump-qemu-${gid}-*" -o -name "vzdump-lxc-${gid}-*" \) ! -name "*.log" ! -name "*.notes" 2>/dev/null | sort -r | head -n1)"
    local out_sz="Desconocido"
    [[ -n "$out_file" && -f "$out_file" ]] && out_sz="$(du -sh "$out_file" 2>/dev/null | awk '{print $1}')"

    if [[ "$v_status" -eq 0 ]]; then
        [[ -n "$out_file" && -f "$out_file" ]] && ENGINE_NEW_ARCHIVES+=("$out_file")
        echo -e "${GREEN}✓ Backup de $gtype $gid completado con éxito ($gname, $out_sz) en $(format_seconds "$gtime").${NC}"
        log_info "Backup de $gtype $gid completado en $(format_seconds "$gtime") (Tamaño: $out_sz)."
        ENGINE_SUMMARY_REPORT+=("✓ [ID $gid] $gtype $gname | $out_sz | $(format_seconds "$gtime")")
    else
        echo -e "${RED}✗ ERROR en el backup de $gtype $gid (Código: $v_status).${NC}"
        log_err "Falló el backup de $gtype $gid (Código $v_status)."
        ENGINE_SUMMARY_REPORT+=("✗ [ID $gid] $gtype $gname | ERROR ($v_status) | $(format_seconds "$gtime")")
        FAILED=1
    fi
    return 0
}

# Fase 9: prueba de integridad de las copias nuevas ANTES de aplicar la retención (ENGINE_VERIFY_FAILED=1 si alguna falla)
motor_verificar_copias_nuevas() {
    ENGINE_VERIFY_FAILED=0
    local new_arch
    [[ ${#ENGINE_NEW_ARCHIVES[@]} -gt 0 ]] || return 0
    echo -e "\n${CYAN}─── Verificando integridad de las copias nuevas (zstd -t / tar -tzf) ───${NC}"
    log_info "Verificando integridad de ${#ENGINE_NEW_ARCHIVES[@]} archivo(s) nuevo(s)..."
    for new_arch in "${ENGINE_NEW_ARCHIVES[@]}"; do
        if test_archive_file "$new_arch"; then
            log_info "Integridad verificada: $(basename "$new_arch")"
        else
            log_err "Integridad FALLIDA en $(basename "$new_arch"): el archivo puede estar corrupto o incompleto."
            ENGINE_SUMMARY_REPORT+=("✗ [VERIFICACIÓN] $(basename "$new_arch") | CORRUPTO | -")
            ENGINE_VERIFY_FAILED=1
            FAILED=1
        fi
    done
    return 0
}

# Fase 10: política de retención por Guest ID y Host (KEEP_LAST); se omite si alguna copia nueva no se verificó
motor_aplicar_retencion() {
    if [[ "$ENGINE_VERIFY_FAILED" -eq 1 ]]; then
        log_warn "Se omite la retención: hay copias nuevas que no superaron la verificación y no se borrarán copias antiguas."
    elif [[ "$KEEP_LAST" -gt 0 && -d "$RUN_DIR" ]]; then
        echo -e "\n${CYAN}─── Retención: Conservar últimas $KEEP_LAST copias por máquina/host ───${NC}"
        prune_old_backups "$RUN_DIR" "$KEEP_LAST" 0
    fi
    return 0
}

# Fase 11: añade a SHA256SUMS las copias que aún no figuran y elimina las entradas de archivos ya purgados
motor_generar_sumas_sha256() {
    echo -e "\n${CYAN}─── Generando sumas de verificación SHA-256 ───${NC}"
    log_info "Calculando sumas de verificación SHA-256..."
    (
        cd "$RUN_DIR"
        find . -maxdepth 1 -type f \( -name "vzdump-*" -o -name "proxmox-host-config-*" \) ! -name "*.log" ! -name "*.notes" ! -name "SHA256SUMS" -printf '%f\n' | sort | while read -r f; do
            if ! grep -q "  $f$" SHA256SUMS 2>/dev/null; then
                sha256sum "$f" >> SHA256SUMS
            fi
        done
    ) 2>/dev/null || true
    sync_sha256sums "$RUN_DIR"
    return 0
}

# Fase 12: imprime el resumen final (destino, tamaño, espacio libre, tiempo y detalle por elemento);
# deja ENGINE_TOTAL_SZ, ENGINE_FINAL_FREE_GB y ENGINE_TOTAL_ELAPSED para la notificación
motor_mostrar_resumen() {
    sync 2>/dev/null || true
    local final_free_kb
    final_free_kb="$(df -Pk "$MOUNTPOINT" | awk 'NR==2 {print $4}')"
    ENGINE_FINAL_FREE_GB=$((final_free_kb / 1024 / 1024))
    ENGINE_TOTAL_ELAPSED=$((SECONDS - START_TIME))
    ENGINE_TOTAL_SZ="$(du -sh "$RUN_DIR" 2>/dev/null | awk '{print $1}')"

    echo
    ui_hr
    if [[ "$FAILED" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}             ¡BACKUP COMPLETADO CON ÉXITO SIN ERRORES!               ${NC}"
    else
        echo -e "${RED}${BOLD}            ¡BACKUP FINALIZADO CON ALGUNOS ERRORES!                  ${NC}"
    fi
    ui_hr
    echo -e "${BOLD}Destino final:${NC}        $RUN_DIR"
    echo -e "${BOLD}Tamaño total en USB:${NC}  ${GREEN}$ENGINE_TOTAL_SZ${NC}"
    echo -e "${BOLD}Espacio libre en USB:${NC} ${GREEN}${ENGINE_FINAL_FREE_GB} GiB${NC}"
    echo -e "${BOLD}Tiempo invertido:${NC}     $(format_seconds "$ENGINE_TOTAL_ELAPSED")"
    echo -e "${BOLD}Log local:${NC}            $HOST_LOG_FILE"
    echo -e "${BOLD}Log en USB:${NC}           $LOG_FILE"
    echo
    echo -e "${BOLD}── Detalle de Elementos Respaldados ─────────────────────────────────${NC}"
    for rep_line in "${ENGINE_SUMMARY_REPORT[@]}"; do
        if [[ "$rep_line" == "✓"* ]]; then
            echo -e "  ${GREEN}$rep_line${NC}"
        else
            echo -e "  ${RED}$rep_line${NC}"
        fi
    done
    echo
    return 0
}

# Fase 13: notificación final (éxito o fallo con el desglose). El fallo va por Telegram y email;
# el éxito por Telegram y, con EMAIL_NOTIFICATION_TYPE=always, también por email. En fallo marca ALERT_SENT=1
motor_notificar_resultado() {
    if [[ "$FAILED" -eq 0 ]]; then
        local tg_msg="✅ <b>Backup Proxmox VE Completado</b>%0A%0A"
        tg_msg+="• <b>Host:</b> $(html_escape "$(hostname)")%0A"
        tg_msg+="• <b>Elementos:</b> ${#ENGINE_SELECTED[@]} VMs/LXCs (+ Host)%0A"
        tg_msg+="• <b>Tamaño en USB:</b> $ENGINE_TOTAL_SZ%0A"
        tg_msg+="• <b>Espacio libre USB:</b> ${ENGINE_FINAL_FREE_GB} GiB%0A"
        tg_msg+="• <b>Tiempo total:</b> $(format_seconds "$ENGINE_TOTAL_ELAPSED")%0A"
        tg_msg+="• <b>Carpeta:</b> <code>$(html_escape "$(basename "$RUN_DIR")")</code>%0A%0A"
        tg_msg+="<b>Desglose por elemento:</b>%0A"
        for rep_line in "${ENGINE_SUMMARY_REPORT[@]}"; do
            tg_msg+="• <code>$(html_escape "$rep_line")</code>%0A"
        done
        send_telegram_message "$tg_msg"
        # En modo 'always' también se envía el resumen por email (en 'failure' solo los fallos)
        [[ "$EMAIL_NOTIFICATION_TYPE" == "always" ]] && send_email_alert "$tg_msg"
        log_info "Notificación de éxito enviada (Telegram$([[ "$EMAIL_NOTIFICATION_TYPE" == "always" && "$EMAIL_ENABLED" -eq 1 ]] && echo " y email"))."
    else
        local tg_err="⚠️ <b>Fallo en Backup Proxmox VE</b>%0A%0A"
        tg_err+="• <b>Host:</b> $(html_escape "$(hostname)")%0A"
        tg_err+="• <b>Estado:</b> Finalizado con errores (vzdump, configuración del host o verificación).%0A"
        tg_err+="• <b>Revisa log:</b> <code>$(html_escape "$HOST_LOG_FILE")</code>%0A%0A"
        tg_err+="<b>Desglose por elemento:</b>%0A"
        for rep_line in "${ENGINE_SUMMARY_REPORT[@]}"; do
            tg_err+="• <code>$(html_escape "$rep_line")</code>%0A"
        done
        send_notifications_alert "$tg_err"
        log_err "Notificación de fallo enviada (Telegram y email, según la configuración)."
        ALERT_SENT=1
    fi
    return 0
}

# Ejecuta el motor desde el menú interactivo en un subshell: un abort o un error inesperado (set -e, exit)
# termina solo el subshell, cuyo trap EXIT (engine_exit_handler) envía la alerta, libera el bloqueo (fd 200)
# y desmonta según MOUNTED_BY_SCRIPT; después se vuelve al menú. Si la copia acaba bien se traslada al menú
# el estado del motor (FAILED, montaje, logs) para que el USB se desmonte al salir, igual que antes.
ejecutar_motor_desde_menu() {
    local state_file rc=0
    state_file="$(mktemp "${TMPDIR:-/tmp}/backup-motor.XXXXXX")"
    # Mientras corre el subshell el menú no actúa ante Ctrl + C: lo gestiona el subshell (mensaje, alerta y limpieza)
    trap ':' INT
    set +e
    (
        set -e
        trap manejar_interrupcion INT
        execute_backup_engine
        printf '%s\n' "$FAILED" "$ALERT_SENT" "$MOUNTED_BY_SCRIPT" "$ENGINE_FINISHED" "$LOG_FILE" "$RUN_DIR" > "$state_file"
        # Copia terminada: el desmontaje queda a cargo del menú (al salir), no del subshell
        trap - EXIT
        exit 0
    )
    rc=$?
    set -e
    trap manejar_interrupcion INT

    if [[ "$rc" -eq 0 ]]; then
        { read -r FAILED; read -r ALERT_SENT; read -r MOUNTED_BY_SCRIPT; read -r ENGINE_FINISHED; read -r LOG_FILE; read -r RUN_DIR; } < "$state_file"
        [[ "$ENGINE_FINISHED" -eq 1 ]] && trap cleanup_mount EXIT
    else
        FAILED=1
        ALERT_SENT=1
        LOG_FILE=""
        mountpoint -q "$MOUNTPOINT" 2>/dev/null || MOUNTED_BY_SCRIPT=0
    fi
    rm -f "$state_file"

    # Ctrl + C durante la copia: se sale del programa como antes (el subshell ya mostró el aviso y limpió)
    [[ "$rc" -eq 130 ]] && exit 130
    if [[ "$rc" -ne 0 ]]; then
        echo -e "\n${YELLOW}↩️  La copia de seguridad terminó con error (código $rc). Bloqueo liberado; volviendo al menú.${NC}"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# MENÚ: Lanzador de Backup (Primer plano o Segundo plano)
# ─────────────────────────────────────────────────────────────────────────────
menu_launch_backup() {
    ui_header "💾 LANZADOR DE COPIA DE SEGURIDAD"

    local running_pids
    running_pids="$(get_running_backup_pids)"
    if [[ -n "$running_pids" ]]; then
        local active_task
        active_task="$(get_active_backup_detail "$running_pids")"
        echo -e "${YELLOW}⚠️ ATENCIÓN: Ya existe un proceso de backup activo en ejecución.${NC}"
        echo -e "   • Estado actual: ${BOLD}$active_task${NC}"
        echo -e "   • PIDs asociados: ${GRAY}$running_pids${NC}\n"
        echo -e " 1) 🛑 ${BOLD}Detener y cancelar la copia en segundo plano activa${NC}"
        echo -e " 2) 📜 ${BOLD}Abrir el visor de progreso en vivo (tail -f)${NC}"
        echo -e " 3) 🚀 Continuar al lanzador de todas formas"
        echo -e " 0) 🚪 Volver al menú principal"
        ui_hr
        read -rp "👉 Elige una opción [1-3, 0]: " active_choice
        case "$active_choice" in
            1)
                stop_running_backup
                return
                ;;
            2)
                ui_header "📜 PROGRESO EN VIVO (Pulsa Ctrl + C para salir)"
                sleep 1
                tail -f "$HOST_LOG_FILE" || true
                return
                ;;
            3)
                ;;
            0|*)
                return
                ;;
        esac
    fi

    CLI_ALL=0
    CLI_HOST_ONLY=0
    CLI_SELECTED_GUESTS=""
    CLI_INCLUDE_HOST=-1
    CLI_DRY_RUN=0

    discover_guests

    echo -e "${BOLD}Paso 1: ¿Qué elementos deseas respaldar?${NC}\n"
    echo -e " 1) 🌐 ${BOLD}Respaldar TODO${NC} (Todas las VMs, Contenedores LXC y Host Proxmox)"
    echo -e " 2) 🎯 ${BOLD}Seleccionar máquinas específicas${NC} (Elegir por ID: ej. 100, 104...)"
    echo -e " 3) 🖥️  ${BOLD}Solo configuración del Host Proxmox${NC} (Red, PVE, hooks, sin VMs)"
    echo -e " 0) 🚪 Volver al menú principal"
    ui_hr
    read -rp "👉 Selecciona qué respaldar [1-3, 0]: " target_opt

    case "$target_opt" in
        1)
            CLI_ALL=1
            CLI_INCLUDE_HOST=1
            ;;
        2)
            echo
            ui_hr
            echo -e "${BOLD}Máquinas y Contenedores detectados en este nodo Proxmox:${NC}"
            if [[ ${#ALL_GUEST_IDS[@]} -eq 0 ]]; then
                echo -e "  ${YELLOW}(No se han detectado VMs ni LXCs en este nodo)${NC}"
                pause_prompt
                return
            fi

            for gid in "${ALL_GUEST_IDS[@]}"; do
                local sz
                sz="$(estimate_guest_disk_gb "$gid")"
                echo -e "  • [ID ${BOLD}$gid${NC}] ${GUEST_TYPES[$gid]} ${BOLD}${GUEST_NAMES[$gid]}${NC} (${GUEST_STATUS[$gid]}) ~${sz} GiB"
            done
            ui_hr
            echo -e "Indica los IDs que deseas respaldar separados por comas (ejemplo: ${BOLD}100,104${NC})"
            read -rp "👉 IDs a respaldar (o '0' para cancelar): " raw_ids
            [[ "$raw_ids" == "0" || -z "$raw_ids" ]] && return

            local valid_ids=()
            local invalid_ids=()
            IFS=',' read -ra INPUT_IDS <<< "$raw_ids"
            for id in "${INPUT_IDS[@]}"; do
                id="$(echo "$id" | tr -d ' ')"
                [[ -z "$id" ]] && continue
                if [[ -n "${GUEST_TYPES[$id]:-}" ]]; then
                    valid_ids+=("$id")
                else
                    invalid_ids+=("$id")
                fi
            done

            if [[ ${#invalid_ids[@]} -gt 0 ]]; then
                echo -e "${YELLOW}⚠️ Los siguientes IDs no existen en Proxmox y se omitirán: ${invalid_ids[*]}${NC}"
            fi

            if [[ ${#valid_ids[@]} -eq 0 ]]; then
                echo -e "${RED}ERROR: No has seleccionado ningún ID válido.${NC}"
                pause_prompt
                return
            fi

            CLI_SELECTED_GUESTS="$(IFS=,; echo "${valid_ids[*]}")"
            echo -e "${GREEN}✓ Máquinas seleccionadas: ${valid_ids[*]}${NC}"

            echo
            if ask_yes_no "¿Deseas incluir también la configuración del Host Proxmox en este respaldo?" "n"; then
                CLI_INCLUDE_HOST=1
            else
                CLI_INCLUDE_HOST=0
            fi
            ;;
        3)
            CLI_HOST_ONLY=1
            CLI_INCLUDE_HOST=1
            ;;
        0|*)
            return
            ;;
    esac

    echo
    ui_hr
    echo -e "${BOLD}Resumen de elementos a respaldar:${NC}"
    if [[ "$CLI_HOST_ONLY" -eq 1 ]]; then
        echo -e "  • Elementos: ${YELLOW}Solo configuración del Host Proxmox (sin máquinas)${NC}"
    elif [[ "$CLI_ALL" -eq 1 ]]; then
        echo -e "  • Elementos: ${GREEN}TODAS las VMs y Contenedores (${#ALL_GUEST_IDS[@]} detectados) + Host Proxmox${NC}"
    else
        echo -e "  • Máquinas seleccionadas: ${GREEN}$CLI_SELECTED_GUESTS${NC}"
        if [[ "$CLI_INCLUDE_HOST" -eq 1 ]]; then
            echo -e "  • Host Proxmox: ${GREEN}SÍ (incluido)${NC}"
        else
            echo -e "  • Host Proxmox: ${YELLOW}NO (omitido)${NC}"
        fi
    fi
    ui_hr

    echo -e "${BOLD}Paso 2: ¿En qué modo deseas ejecutar el respaldo?${NC}\n"
    echo -e " 1) 🖥️  ${BOLD}PRIMER PLANO${NC} (Interactivo, con progreso en pantalla en tiempo real)"
    echo -e " 2) 🚀 ${BOLD}SEGUNDO PLANO${NC} (Desatendido con nohup, permite cerrar la sesión SSH)"
    echo -e " 3) 🧪 ${BOLD}SIMULACIÓN (Dry-Run)${NC} (Comprobar qué se respaldaría y purgaría sin escribir)"
    echo -e " 0) 🚪 Cancelar y volver al menú principal"
    ui_hr
    read -rp "👉 Elige el modo de ejecución [1-3, 0]: " run_mode

    case "$run_mode" in
        1)
            ejecutar_motor_desde_menu
            pause_prompt
            ;;
        2)
            echo -e "\n${CYAN}Preparando e iniciando backup en segundo plano (nohup)...${NC}"
            if ! ensure_no_backup_running "lanzar otra copia"; then
                pause_prompt
                return
            fi
            # Desmontar solo si en $MOUNTPOINT está nuestro USB (el proceso hijo lo montará y desmontará al terminar)
            if is_our_usb_mounted; then
                umount "$MOUNTPOINT" 2>/dev/null || true
            fi
            # El montaje pasa a ser responsabilidad del proceso en segundo plano: el menú no debe desmontarlo al salir
            MOUNTED_BY_SCRIPT=0

            local bg_args=("-y")
            if [[ "$CLI_ALL" -eq 1 ]]; then
                bg_args+=("--all")
            elif [[ "$CLI_HOST_ONLY" -eq 1 ]]; then
                bg_args+=("--host-only")
            elif [[ -n "$CLI_SELECTED_GUESTS" ]]; then
                bg_args+=("--vms" "$CLI_SELECTED_GUESTS")
                if [[ "$CLI_INCLUDE_HOST" -eq 1 ]]; then
                    bg_args+=("--with-host")
                else
                    bg_args+=("--no-host")
                fi
            fi

            nohup bash "$0" "${bg_args[@]}" >/dev/null 2>&1 &
            local bg_pid=$!
            echo -e "${GREEN}✓ Proceso lanzado en segundo plano con PID: $bg_pid${NC}"
            echo -e "  Comando ejecutado: ${GRAY}bash $0 ${bg_args[*]}${NC}"
            echo -e "  El registro en vivo se está guardando en: ${BOLD}$HOST_LOG_FILE${NC}\n"
            echo -e "Ya puedes cerrar la terminal si lo deseas."
            echo
            if ask_yes_no "¿Deseas abrir ahora el visor de log en vivo (tail -f)?" "s"; then
                ui_header "📜 PROGRESO EN VIVO (Pulsa Ctrl + C para salir)"
                sleep 1
                tail -f "$HOST_LOG_FILE" || true
            fi
            ;;
        3)
            CLI_DRY_RUN=1
            ejecutar_motor_desde_menu
            CLI_DRY_RUN=0
            pause_prompt
            ;;
        0|*)
            return
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# INICIALIZACIÓN: Detección y Auto-Montaje Inteligente de USB al Iniciar
# ─────────────────────────────────────────────────────────────────────────────
init_usb_selection_and_mount() {
    load_config

    # 1. Si ya está montado o el dispositivo configurado está conectado y monta limpiamente, entrar directo al panel
    if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        return 0
    fi
    if [[ -n "$USB_UUID" && -e "/dev/disk/by-uuid/$USB_UUID" ]]; then
        if mount_usb_device 2>/dev/null; then
            MOUNTED_BY_SCRIPT=0
            return 0
        fi
    fi

    ui_header "🔌 INICIALIZACIÓN DE DISCO USB DE COPIAS (PROXMOX VE)"
    echo -e "${YELLOW}El disco configurado (${USB_UUID:-sin configurar}) no está montado o no se detecta actualmente.${NC}"
    echo -e "Buscando dispositivos de almacenamiento externos / USB..."

    local candidates=()
    mapfile -t candidates < <(scan_usb_candidates)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo -e "\n${YELLOW}⚠️ No se detectó ninguna unidad USB o partición externa disponible.${NC}"
        echo -e "Asegúrate de que el disco USB esté enchufado físicamente al servidor Proxmox."
        ui_hr
        echo -e " ${YELLOW}1)${NC} 🔄 Reintentar detección"
        echo -e " ${YELLOW}2)${NC} 🚪 Continuar al panel principal sin montar (modo consulta)"
        ui_hr
        read -rp "👉 Opción [1-2]: " no_usb_opt
        if [[ "$no_usb_opt" == "1" ]]; then
            init_usb_selection_and_mount
            return
        else
            return
        fi
    fi

    echo -e "\n${BOLD}Unidades de almacenamiento detectadas:${NC}\n"
    local idx=1
    declare -A MAP_DEV_UUID
    declare -A MAP_DEV_NAME
    local default_idx=""

    for cand in "${candidates[@]}"; do
        # PKNAME se declara local para que el eval de la salida de lsblk no cree una variable global
        # shellcheck disable=SC2034
        local NAME="" SIZE="" FSTYPE="" LABEL="" UUID="" TRAN="" MODEL="" TYPE="" PKNAME="" DEV_MOUNTPOINT=""
        eval "${cand//MOUNTPOINT=/DEV_MOUNTPOINT=}"

        local tag=""
        local is_usb_tag=""
        [[ "$TRAN" == "usb" ]] && is_usb_tag="${CYAN}(USB Externo)${NC} "
        [[ -n "$MODEL" ]] && is_usb_tag+="${GRAY}[$MODEL]${NC} "

        if [[ "$UUID" == "$USB_UUID" ]]; then
            tag=" ${GREEN}${BOLD}[PREDETERMINADO / GUARDADO]${NC}"
            default_idx="$idx"
        fi

        local lbl_info=""
        [[ -n "$LABEL" ]] && lbl_info=" \"$LABEL\""

        echo -e "  ${YELLOW}$idx)${NC} /dev/$NAME ($SIZE) [$FSTYPE]$lbl_info $is_usb_tag$tag"
        echo -e "      └─> UUID: ${BOLD}$UUID${NC}"
        MAP_DEV_UUID["$idx"]="$UUID"
        MAP_DEV_NAME["$idx"]="/dev/$NAME"
        ((++idx))
    done

    echo
    ui_hr
    if [[ -n "$default_idx" ]]; then
        echo -e "Presiona ${BOLD}[Enter]${NC} para montar la opción predeterminada ${BOLD}($default_idx)${NC}"
    fi
    echo -e "o escribe el número ${BOLD}[1-$((idx-1))]${NC} del USB que deseas usar y montar,"
    echo -e "o escribe ${BOLD}s${NC} para saltar e ir al panel sin montar."
    ui_hr
    read -rp "👉 Selección [Enter=$default_idx]: " chosen_idx
    chosen_idx="${chosen_idx:-$default_idx}"

    if [[ "$chosen_idx" =~ ^[sS]$ || -z "$chosen_idx" ]]; then
        return
    fi

    MOUNTPOINT="${MOUNTPOINT:-/media/backup}"

    local selected_uuid="${MAP_DEV_UUID[$chosen_idx]:-}"
    if [[ -n "$selected_uuid" ]]; then
        USB_UUID="$selected_uuid"
        save_config
        echo -e "\n${CYAN}Montando ${MAP_DEV_NAME[$chosen_idx]} ($USB_UUID) en $MOUNTPOINT...${NC}"
        if ensure_no_backup_running "montar otro disco"; then
            umount "$MOUNTPOINT" 2>/dev/null || true
        fi
        if mount_usb_device; then
            MOUNTED_BY_SCRIPT=0
            local free_space
            free_space="$(df -h "$MOUNTPOINT" 2>/dev/null | awk 'NR==2 {print $4}')"
            echo -e "${GREEN}${BOLD}✓ ¡Disco USB montado con éxito en $MOUNTPOINT! ($free_space libres)${NC}\n"
            sleep 1
        else
            echo -e "${RED}ERROR: No se pudo montar el disco seleccionado.${NC}"
            pause_prompt
        fi
    else
        echo "Opción no reconocida. Continuando al menú principal..."
        sleep 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MENÚ PRINCIPAL (TUI UNIFICADO)
# ─────────────────────────────────────────────────────────────────────────────
main_menu() {
    load_config
    while true; do
        ui_header "🛡️ PANEL DE GESTIÓN Y BACKUP PROXMOX VE A USB ($(hostname -s 2>/dev/null || echo pve))"

        local usb_state="${RED}🔴 No conectado (${USB_UUID:-sin UUID})${NC}"
        if [[ -n "$USB_UUID" && -e "/dev/disk/by-uuid/$USB_UUID" ]]; then
            local rdev fst
            rdev="$(readlink -f "/dev/disk/by-uuid/$USB_UUID")"
            fst="$(blkid -s TYPE -o value "$rdev" 2>/dev/null || echo "desconocido")"
            if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
                local df_info tot_h used_h free_h used_pct pct_num
                df_info="$(df -h "$MOUNTPOINT" 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}')"
                read -r tot_h used_h free_h used_pct <<< "${df_info:-0G 0G 0G 0%}"
                pct_num="${used_pct%%%}"
                usb_state="${GREEN}🟢 MONTADO${NC} ($MOUNTPOINT | $rdev [$fst]) $(ui_progress_bar "$pct_num" 14) ${GREEN}${free_h} libres${NC}"
            else
                usb_state="${YELLOW}🟡 Detectado: $rdev [$fst] (Desmontado)${NC}"
            fi
        fi

        local tg_st="${RED}OFF${NC}"
        [[ "$TELEGRAM_ENABLED" -eq 1 ]] && tg_st="${GREEN}ON${NC}"
        local mail_st="${RED}OFF${NC}"
        if [[ "$EMAIL_ENABLED" -eq 1 ]]; then
            mail_st="${GREEN}ON (${NOTIFICATION_TARGET:-Nativo})${NC}"
        fi

        local cron_info cron_st="${RED}Desactivado${NC}"
        cron_info="$(get_cron_entry)"
        if [[ -n "$cron_info" ]]; then
            local short_c
            short_c="$(echo "$cron_info" | awk '{print $1,$2,$3,$4,$5}')"
            cron_st="${GREEN}Activado ($short_c)${NC}"
        fi

        local z_str="Auto"
        [[ "$ZSTD_THREADS" -gt 0 ]] && z_str="${ZSTD_THREADS}c"
        local bw_str="Max"
        [[ "$BWLIMIT" -gt 0 ]] && bw_str="$((BWLIMIT/1024))MB/s"
        local bl_str="Ninguna"
        [[ -n "$BLACKLIST_VMS" ]] && bl_str="$BLACKLIST_VMS"

        local bg_pids bg_st="${GREEN}Inactivo (sin tareas en curso)${NC}" bg_detail=""
        bg_pids="$(get_running_backup_pids)"
        if [[ -n "$bg_pids" ]]; then
            bg_st="${YELLOW}${BOLD}⚡ EN EJECUCIÓN (PIDs: $bg_pids)${NC}"
            local task_info
            task_info="$(get_active_backup_detail "$bg_pids")"
            bg_detail="      └─> ${CYAN}Progreso:${NC} ${BOLD}$task_info${NC}"
        fi

        echo -e " 💽 ${BOLD}USB:${NC}          $usb_state"
        echo -e " 🔄 ${BOLD}Estado Tarea:${NC} $bg_st"
        [[ -n "$bg_detail" ]] && echo -e "$bg_detail"
        echo -e " ⚡ ${BOLD}Ajustes:${NC}      Retención [${BOLD}${KEEP_LAST}${NC} copias] | ZSTD [${CYAN}$z_str${NC}] | I/O [${CYAN}$bw_str${NC}] | Blacklist [${YELLOW}$bl_str${NC}]"
        echo -e " 🔔 ${BOLD}Alertas/Cron:${NC} Cron [$cron_st] | Telegram [$tg_st] | Proxmox Mail [$mail_st]"
        ui_hr

        echo -e " ${CYAN}── 🚀 Copias de Seguridad y Restauración ──${NC}"
        echo -e "  ${YELLOW}1)${NC} 💾 ${BOLD}Lanzar Copia de Seguridad${NC} (Primer plano, Segundo plano o Simulación)"
        if [[ -n "$bg_pids" ]]; then
            echo -e "  ${YELLOW}2)${NC} 🛑 ${RED}${BOLD}Detener Copia en Curso${NC} (Cancelar tarea activa en segundo plano)"
        else
            echo -e "  ${YELLOW}2)${NC} 🛑 ${BOLD}Detener Copia / Liberar Locks${NC} (qm/pct unlock de bloqueos residuales)"
        fi
        echo -e "  ${YELLOW}3)${NC} 🔄 ${BOLD}Restaurar Copia de Seguridad${NC} (VMs QEMU, Contenedores LXC o Host)"
        echo -e "  ${YELLOW}4)${NC} 📊 ${BOLD}Calculadora de Espacio Requerido${NC} (Desglose de discos y passthrough)"
        echo
        echo -e " ${CYAN}── 💽 Almacenamiento USB y Discos ──${NC}"
        echo -e "  ${YELLOW}5)${NC} 🔌 ${BOLD}Centro de Almacenamiento USB${NC} (Montar, Desmontar, Cambiar UUID o Formatear)"
        echo -e "  ${YELLOW}6)${NC} 📦 ${BOLD}Gestor de Copias e Integridad${NC} (Tabla, Purgar antiguas, Test zstd/SHA256)"
        echo -e "  ${YELLOW}7)${NC} ⚙️  ${BOLD}Gestionar Discos y Passthrough${NC} (Activar/Desactivar backup=0 en VMs y LXCs)"
        echo
        echo -e " ${CYAN}── 🛠️ Automatización, Ajustes y Diagnóstico ──${NC}"
        echo -e "  ${YELLOW}8)${NC} 📅 ${BOLD}Programar Backup Automático${NC} (Asistente Crontab diario/semanal/mensual)"
        echo -e "  ${YELLOW}9)${NC} ⚡ ${BOLD}Retención ($KEEP_LAST), Rendimiento (ZSTD/bwlimit) y Lista Negra${NC}"
        echo -e " ${YELLOW}10)${NC} 🔔 ${BOLD}Configurar Notificaciones${NC} (Telegram Bot y Destinos Proxmox VE)"
        echo -e " ${YELLOW}11)${NC} 🔍 ${BOLD}Diagnóstico de Salud SMART y Kernel${NC} | ${YELLOW}12)${NC} 📜 ${BOLD}Visor de Logs${NC} | ${YELLOW}?)${NC} ❓ ${BOLD}Ayuda${NC}"
        echo -e "  ${YELLOW}0)${NC} 🚪 ${BOLD}Salir${NC} ${GRAY}(Atajos: c=Cambiar USB, f=Formatear, l=Logs, h=Salud, q=Salir)${NC}"
        ui_hr
        read -rp "👉 Elige una opción [0-12 / ? / q]: " main_opt

        case "$main_opt" in
            1) menu_launch_backup ;;
            2) stop_running_backup ;;
            3|r|R) menu_restore_backup ;;
            4) menu_disk_calculator ;;
            5|u|U) menu_mount_umount_usb ;;
            6) menu_manage_backups ;;
            7|d|D) menu_manage_disks ;;
            8) menu_cron_schedule ;;
            9) menu_performance_and_blacklist ;;
            10|n|N) menu_notifications ;;
            11|h|H) menu_disk_health ;;
            12|13|l|L) menu_manage_logs ;;
            c|C) menu_select_usb ;;
            f|F) menu_format_usb ;;
            14) menu_notifications ;;
            15|\?|help|ayuda) menu_help ;;
            0|q|Q)
                echo -e "\n${GREEN}👋 ¡Hasta pronto!${NC}"
                exit 0
                ;;
            *)
                echo "Opción no válida."
                sleep 1
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Procesamiento de Argumentos CLI (Automatización / Cron)
# ─────────────────────────────────────────────────────────────────────────────
show_help() {
    local rc="${1:-0}"
    cat <<EOF
Uso: $0 [OPCIONES]

Suite de respaldo a USB externo para Proxmox VE con menú de gestión.

Si se ejecuta sin opciones, se abre el Menú Principal Interactivo.

Opciones de Línea de Comandos (CLI / Cron):
  -a, --all              Respalda automáticamente todas las VMs, LXCs y host.
  -y, --yes              Omite confirmaciones interactivas (asume 'SÍ').
  -n, --dry-run          Simula la ejecución y la purga sin escribir ni borrar nada.
  --vms <id1,id2,...>    Especifica lista de IDs a respaldar (ej: --vms 100,104).
  --with-host            Incluye el respaldo del host al usar --vms.
  --no-host              Excluye el respaldo del host al usar --vms o --all.
  --host-only            Respalda únicamente la configuración del host Proxmox.
  --keep <N>             Sobrescribe el número de copias a retener.
  --uuid <UUID>          Sobrescribe el UUID del disco USB a usar.
  --zstd <N>             Sobrescribe número de hilos CPU de compresión zstd.
  --bwlimit <KB/s>       Sobrescribe límite de ancho de banda I/O en KiB/s.
  --blacklist <id1,id2>  Sobrescribe lista negra de exclusión de VMs.
  --bg, --background     Lanza la tarea automáticamente en segundo plano.
  --stop, --kill         Detiene de forma limpia y cancela cualquier backup activo.
                         Sin terminal (cron, nohup) no pregunta: sin -y no detiene nada
                         (sale con código 1 si había una copia en curso); con -y la detiene.
  --mount                Monta el disco USB configurado en $MOUNTPOINT y sale.
  --umount               Desmonta de forma segura $MOUNTPOINT y sale.
  --cron-status          Muestra la programación activa de cron y sale.
  --cron-remove          Elimina la tarea automática de cron y sale.
  --telegram-test        Envía un mensaje de prueba a Telegram y sale.
  -h, --help             Muestra esta ayuda.

Ejemplos:
  $0                         # Abre el menú interactivo completo
  $0 --all -y                # Backup completo desatendido (para cron o nohup)
  $0 --all --dry-run         # Simula el backup completo y muestra qué se purgaría
  $0 --stop                  # Detiene cualquier copia en segundo plano activa
  $0 --vms 100,104 -y        # Backup únicamente de VM 100 y 104
  $0 --vms 100,104 --with-host -y # Backup de VMs 100, 104 y configuración del host
  $0 --mount                 # Monta manualmente el disco USB
  $0 --umount                # Desmonta de forma segura el disco USB
  $0 --cron-status           # Consulta el horario programado en cron

Códigos de salida: 0 = correcto · 1 = la copia falló o no pudo empezar · 2 = opciones no válidas
EOF
    exit "$rc"
}

# Error de uso en la línea de comandos: mensaje por stderr y salida con código 2 (cron lo detecta)
cli_usage_error() {
    echo "ERROR: $*" >&2
    echo "Usa '$0 --help' para ver las opciones disponibles." >&2
    exit 2
}

# Comprueba que una opción que necesita valor lo recibe (y que no es otra opción, p. ej. '--keep --all')
cli_require_value() {
    local opt="$1"
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        cli_usage_error "La opción $opt necesita un valor."
    fi
}

cli_require_number() {
    local opt="$1" val="$2"
    [[ "$val" =~ ^[0-9]+$ ]] || cli_usage_error "La opción $opt necesita un número entero (recibido: '$val')."
}

# Procesar argumentos si existen
load_config
# Migrar la tarea de cron de versiones anteriores (salida a /dev/null) y acotar el tamaño de su log
upgrade_legacy_cron_entry || true
rotate_cron_log || true
if [[ $# -gt 0 ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all) CLI_ALL=1; shift ;;
            -y|--yes) CLI_YES=1; shift ;;
            -n|--dry-run) CLI_DRY_RUN=1; shift ;;
            --host-only) CLI_HOST_ONLY=1; shift ;;
            --vms) cli_require_value "$@"; [[ "$2" =~ ^[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*$ ]] || cli_usage_error "La opción --vms necesita IDs numéricos separados por comas (recibido: '$2')."; CLI_SELECTED_GUESTS="$2"; shift 2 ;;
            --with-host) CLI_INCLUDE_HOST=1; shift ;;
            --no-host) CLI_INCLUDE_HOST=0; shift ;;
            --keep) cli_require_value "$@"; cli_require_number "$1" "$2"; KEEP_LAST="$2"; shift 2 ;;
            --uuid) cli_require_value "$@"; USB_UUID="$2"; shift 2 ;;
            --zstd) cli_require_value "$@"; cli_require_number "$1" "$2"; ZSTD_THREADS="$2"; shift 2 ;;
            --bwlimit) cli_require_value "$@"; cli_require_number "$1" "$2"; BWLIMIT="$2"; shift 2 ;;
            --blacklist) cli_require_value "$@"; [[ "$2" =~ ^[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*$ ]] || cli_usage_error "La opción --blacklist necesita IDs numéricos separados por comas (recibido: '$2')."; BLACKLIST_VMS="$2"; shift 2 ;;
            --bg|--background) CLI_BACKGROUND=1; shift ;;
            --stop|--kill) CLI_STOP=1; shift ;;
            --mount)
                if mount_usb_device; then
                    echo "✓ Disco USB montado con éxito en $MOUNTPOINT"
                    df -h "$MOUNTPOINT" 2>/dev/null || true
                    exit 0
                else
                    echo "ERROR: No se pudo montar el disco USB ($USB_UUID)"
                    exit 1
                fi
                ;;
            --umount)
                ensure_no_backup_running "desmontar el USB" || exit 1
                sync
                if umount "$MOUNTPOINT" 2>/dev/null || umount -l "$MOUNTPOINT" 2>/dev/null; then
                    echo "✓ Disco USB desmontado con éxito de $MOUNTPOINT"
                    exit 0
                else
                    echo "ERROR: No se pudo desmontar $MOUNTPOINT"
                    exit 1
                fi
                ;;
            --cron-status)
                c_job="$(get_cron_entry)"
                if [[ -n "$c_job" ]]; then
                    echo "Tarea de Cron activa:"
                    echo "  • Horario: $(format_cron_human "$c_job")"
                    echo "  • Entrada crontab: $c_job"
                else
                    echo "No hay ninguna tarea automática de backup configurada en crontab."
                fi
                exit 0
                ;;
            --cron-remove)
                replace_cron_entry
                echo "✓ Tarea de backup eliminada de crontab."
                exit 0
                ;;
            --telegram-test)
                send_telegram_message "🔔 Test de Telegram desde línea de comandos."
                echo "Mensaje enviado."
                exit 0
                ;;
            -h|--help) show_help 0 ;;
            *)
                echo "ERROR: Opción desconocida: $1" >&2
                echo >&2
                show_help 2 >&2
                ;;
        esac
    done

    # --stop se atiende tras leer todos los argumentos (así '-y' vale en cualquier posición) e ignora el resto
    if [[ "$CLI_STOP" -eq 1 ]]; then
        stop_running_backup
        exit "$STOP_RC"
    fi

    # Validar también los valores recibidos por CLI (--keep, --zstd, --bwlimit, --blacklist)
    validate_settings

    if [[ "$CLI_BACKGROUND" -eq 1 ]]; then
        ensure_no_backup_running "lanzar otra copia" || exit 1
        # Desmontar solo si en $MOUNTPOINT está nuestro USB (el proceso hijo lo montará y desmontará al terminar)
        if is_our_usb_mounted; then
            umount "$MOUNTPOINT" 2>/dev/null || true
        fi
        bg_args=("-y")
        [[ "$CLI_ALL" -eq 1 ]] && bg_args+=("--all")
        [[ "$CLI_HOST_ONLY" -eq 1 ]] && bg_args+=("--host-only")
        [[ -n "$CLI_SELECTED_GUESTS" ]] && bg_args+=("--vms" "$CLI_SELECTED_GUESTS")
        [[ "$CLI_INCLUDE_HOST" -eq 1 ]] && bg_args+=("--with-host")
        [[ "$CLI_INCLUDE_HOST" -eq 0 ]] && bg_args+=("--no-host")
        [[ "$CLI_DRY_RUN" -eq 1 ]] && bg_args+=("--dry-run")
        # Reenviar siempre los ajustes efectivos (backup.conf + overrides de CLI) al proceso en segundo plano
        bg_args+=("--keep" "$KEEP_LAST" "--zstd" "$ZSTD_THREADS" "--bwlimit" "$BWLIMIT")
        [[ -n "$USB_UUID" ]] && bg_args+=("--uuid" "$USB_UUID")
        [[ -n "$BLACKLIST_VMS" ]] && bg_args+=("--blacklist" "$BLACKLIST_VMS")

        nohup bash "$0" "${bg_args[@]}" >/dev/null 2>&1 &
        bg_pid=$!
        echo "✓ Proceso lanzado en segundo plano con PID $bg_pid"
        echo "  Comando: bash $0 ${bg_args[*]}"
        exit 0
    else
        execute_backup_engine
        exit "$FAILED"
    fi
else
    # Sin argumentos: Inicializar/montar USB inteligentemente antes de mostrar el menú principal
    MENU_MODE=1
    init_usb_selection_and_mount
    main_menu
fi
