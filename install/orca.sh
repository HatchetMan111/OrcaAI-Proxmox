#!/usr/bin/env bash
#
# Orca Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Orca – ADE Remote Server (orca serve, headless)
# Upstream: https://github.com/stablyai/orca
# Stack:    Prebuilt orca-linux.AppImage (--appimage-extract, ohne FUSE)
#           + systemd orca.service (:6768), ohne Docker, ohne Cloud
# Läuft:    vollständig lokal im LXC, keine externen Cloud-Dienste nötig
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OrcaAI-Proxmox/main/install/orca.sh)"
#   CT_ID=150 CORES=2 RAM=4096 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OrcaAI-Proxmox/main/install/orca.sh)"
#   bash orca.sh --ctid 150 --cores 2 --memory 4096 --disk 20 --bridge vmbr0 --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="orca"                                        # Container-Hostname + Service-Name
APP_PORT="6768"                                   # orca serve Endpoint + Pairing
UPSTREAM_REPO="https://github.com/stablyai/orca"
INSTALLER_REPO="https://github.com/HatchetMan111/OrcaAI-Proxmox"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/OrcaAI-Proxmox/main/systemd/orca.service"

DEFAULT_CORES="2"                                 # vCPU (Electron-Prebuilt + Extract)
DEFAULT_RAM="4096"                                # RAM in MB
DEFAULT_SWAP="1024"                               # Swap (MB)
DEFAULT_DISK="20"                                 # Disk in GB
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                    # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"                   # Template-Familie
UNPRIVILEGED="1"                                  # 1 = unprivilegiert (reicht hier)
FEATURES="nesting=1"                              # nesting für AppImage-Extract Robustheit

APP_USER="orca"
DATA_DIR="/var/lib/orca"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=4096 DISK=20 ./orca.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollständiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer (orca serve :${APP_PORT})

Usage:
  bash orca.sh [OPTIONEN]
  CT_ID=150 bash orca.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO}/main/install/orca.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --source-build       Orca aus Source bauen statt Prebuilt-AppImage (langsamer)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG="" SOURCE_BUILD="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --source-build) SOURCE_BUILD="1"; shift;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Prüfung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer nächste freie ID, außer --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Nächste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfügbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Prüfe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfügbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell prüfen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – überspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge prüfen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. Orca im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere Orca (Prebuilt-AppImage, ohne FUSE) im Container ..."
# Hinweis: aeussere Single-Quotes – der Block laeuft dadurch 1:1 im Container,
# ohne dass die Host-Shell $ oder $(...) anfasst (kein Escaping noetig).
# Darum: in diesen Bloecken KEINE einfachen Anfuehrungszeichen verwenden.
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates git squashfs-tools procps iproute2 \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxrandr2 libgbm1 libasound2 libpango-1.0-0 libcairo2 \
    libgtk-3-0 libxfixes3
  id orca >/dev/null 2>&1 || useradd -m -s /bin/bash orca
  mkdir -p /opt/orca /var/lib/orca
  chown orca:orca /opt/orca /var/lib/orca
'
if [[ "$SOURCE_BUILD" == "1" ]]; then
  msg_info "Source-Build-Modus (--source-build): Checkout nach /opt/orca-src ..."
  pct exec "$CT_ID" -- bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y nodejs npm git curl ca-certificates
    npm install -g pnpm
    if [ ! -d /opt/orca-src/.git ]; then
      rm -rf /opt/orca-src
      git clone --depth 1 https://github.com/stablyai/orca /opt/orca-src
    else
      git -C /opt/orca-src pull --ff-only
    fi
    ln -sf /opt/orca-src/out/cli/index.js /usr/local/bin/orca-src-index || true
  '
  msg_warn "Source-Checkout liegt unter /opt/orca-src – Build per pnpm im Container nachholen (30-60 Min)."
  msg_warn "Fuer orca serve wird weiterhin /usr/local/bin/orca benoetigt – ggf. manuell verlinken."
else
  pct exec "$CT_ID" -- bash -c '
    set -euo pipefail
    cd /opt/orca
    TAG="$(curl -fsSL https://api.github.com/repos/stablyai/orca/releases/latest | grep -oP "\"tag_name\":\\s*\"\\K[^\"]+" || true)"
    if [ -z "$TAG" ]; then
      URL="$(curl -fsSL -o /dev/null -w "%{url_effective}" https://github.com/stablyai/orca/releases/latest)"
      TAG="$(basename "$URL")"
    fi
    test -n "$TAG"
    echo "Orca-Release: $TAG"
    curl -fSL -o orca-linux.AppImage "https://github.com/stablyai/orca/releases/download/${TAG}/orca-linux.AppImage"
    chmod +x orca-linux.AppImage
    rm -rf squashfs-root
    ./orca-linux.AppImage --appimage-extract >/dev/null
    chmod +x squashfs-root/AppRun 2>/dev/null || true
    ls squashfs-root | head -n 30
    BIN=""
    DESK="$(ls squashfs-root/*.desktop 2>/dev/null | head -n1 || true)"
    if [ -n "$DESK" ]; then
      EXECLINE="$(grep -m1 ^Exec= "$DESK" | cut -d= -f2- || true)"
      CAND="${EXECLINE%% *}"
      if [ -n "$CAND" ] && [ -x "squashfs-root/$CAND" ]; then BIN="squashfs-root/$CAND"; fi
    fi
    if [ -z "$BIN" ]; then
      for CAND in squashfs-root/AppRun squashfs-root/orca-ide squashfs-root/orca squashfs-root/usr/bin/orca squashfs-root/usr/bin/orca-ide; do
        if [ -x "$CAND" ]; then BIN="$CAND"; break; fi
      done
    fi
    test -n "$BIN"
    echo "Orca-Entry: $BIN (Desktop: ${DESK:-keine})"
    ln -sf "/opt/orca/${BIN}" /usr/local/bin/orca
    su -s /bin/bash orca -c "/usr/local/bin/orca --version" || su -s /bin/bash orca -c "/usr/local/bin/orca status --json" || true
  '
fi
# Hinweis: bewusst kein '| tail' hier – mit pipefail wuerde der trap sonst
# die Pipe statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

# Host-seitiger Guard: bricht laut ab, falls kein ausfuehrbares Binary da ist –
# schuetzt vor Geister-Installation bei geaendertem AppImage-Layout.
pct exec "$CT_ID" -- test -x /usr/local/bin/orca \
  || { msg_error "Orca-Binary fehlt: /usr/local/bin/orca nicht ausfuehrbar (AppImage-Layout pruefen)."; pct exec "$CT_ID" -- ls -la /opt/orca/squashfs-root 2>/dev/null || true; exit 1; }
msg_ok "Orca-Binary ok (/usr/local/bin/orca)."

# systemd-Unit aus diesem Repo übernehmen (fällt auf Inline-Unit zurück)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/orca.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "orca.service aus Repo übernommen."
  pct exec "$CT_ID" -- bash -c "sed -i 's/__CT_IP__/${CT_IP}/g' /etc/systemd/system/orca.service"
  grep -q "__CT_IP__" <(pct exec "$CT_ID" -- cat /etc/systemd/system/orca.service) \
    && { msg_error "Platzhalter __CT_IP__ wurde nicht ersetzt."; exit 1; }
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/orca.service <<UNIT
[Unit]
Description=Orca Remote Server (orca serve, headless)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${DATA_DIR}
Environment=HOME=${DATA_DIR}
ExecStart=/usr/local/bin/orca serve --port ${APP_PORT} --pairing-address ${CT_IP}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now orca

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + orca serve Endpoint
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active orca || { msg_error "systemd-Service orca ist nicht active."; pct exec "$CT_ID" -- systemctl status orca --no-pager || true; exit 1; }
msg_ok "Service läuft (systemctl is-active orca = active)."

# Hinweis: / liefert nicht garantiert HTTP 200 (ggf. 404) – darum zaehlt jeder
# Status ausser 000 (keine TCP-Verbindung) als "antwortet".
msg_info "Warte auf orca serve (max. 3 Min) ..."
WEB_OK=0
PAIR_CODE="000"
for _ in $(seq 1 18); do
  PAIR_CODE="$(pct exec "$CT_ID" -- curl -s -o /dev/null -w '%{http_code}' -m 10 "http://localhost:${APP_PORT}/" 2>/dev/null || echo 000)"
  if [[ "$PAIR_CODE" != "000" ]]; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "orca serve antwortet nicht auf localhost:${APP_PORT}."; pct exec "$CT_ID" -- systemctl status orca --no-pager || true; pct exec "$CT_ID" -- journalctl -u orca --no-pager -n 100 || true; pct exec "$CT_ID" -- ss -ltn || true; exit 1; }
msg_ok "orca serve antwortet (HTTP ${PAIR_CODE} auf localhost:${APP_PORT})."

PAIR_URL="$(pct exec "$CT_ID" -- journalctl -u orca --no-pager -n 200 2>/dev/null | grep -oP 'orca://pair\?[^ ]+' | tail -n1 || true)"
[[ -n "${PAIR_URL:-}" ]] || PAIR_URL="<siehe journalctl -u orca im Container>"

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Orca – ADE Remote Server (orca serve, headless)"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Endpoint     : http://${CT_IP}:${APP_PORT}"
echo "  Pairing      : ${PAIR_URL}"
echo "  Client-Setup : Laptop-Orca → Settings → Remote Orca Servers → Add Server → Link einfügen"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unverändert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status orca  (im Container via: pct enter $CT_ID)"
echo "  Update       : Skript erneut laufen lassen (idempotent, Release-Refresh + Restart)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -s -o /dev/null -w '%{http_code}' http://${CT_IP}:${APP_PORT}"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
