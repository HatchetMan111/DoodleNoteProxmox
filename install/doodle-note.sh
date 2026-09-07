#!/usr/bin/env bash
#
# DoodleNote (Web Workspace / Sync Server) — Proxmox LXC Einzeiler-Installer
# Stil: angelehnt an community-scripts.github.io/ProxmoxVE (pct create + Setup im CT)
#
# Einzeiler (auf dem Proxmox-Host als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DoodleNoteProxmox/main/install/doodle-note.sh)"
# Debug bei Fehlern:
#   DEBUG=1 bash -x doodle-note.sh
#
# Scope-Hinweis: Im LXC läuft NUR apps/web (Next.js Sync-Server, Port 4040).
# Die Desktop-Capture/Transkription (Electron + Swift engine/) braucht macOS
# Apple Silicon bzw. Windows mit GUI/Mikrofon und kann nicht headless im LXC laufen.
#
# Upstream: https://github.com/Onyx-Dev-Labs/doodle-note
# Self-Hosting-Doku: SELF-HOSTING.md / apps/web/README.md im Upstream-Repo

set -euo pipefail

# ============================================================================
# Variablen (oben, Community-Scripts-konform anpassbar)
# ============================================================================
APP_NAME="doodle-note"
HOSTNAME_DEFAULT="doodle-note"
UPSTREAM_REPO="https://github.com/Onyx-Dev-Labs/doodle-note.git"
UPSTREAM_BRANCH="main"

WEB_PORT="4040"          # apps/web: `next start --port 4040`
APP_DIR="/opt/doodle-note"
ENV_DIR="/etc/doodle-note"
ENV_FILE="/etc/doodle-note/doodle-note.env"

CTID_DEFAULT=""          # leer = nächste freie ID ab 100
CPU_DEFAULT="2"          # Next.js-Build braucht 2 vCPU (1 vCPU -> OOM-Risiko)
RAM_DEFAULT="4096"       # 4 GB (Build + Postgres + Next; unter 2 GB instabil)
DISK_DEFAULT="12"        # GB (node_modules + .next + Postgres)
STORAGE_DEFAULT="local-lvm"
TEMPLATE_STORAGE_DEFAULT="local"
TEMPLATE_DEFAULT="debian-12-standard_12.7-1_amd64.tar.zst"
BRIDGE_DEFAULT="vmbr0"
NET_DEFAULT="dhcp"       # "dhcp" oder statisch "10.0.0.50/24,gw=10.0.0.1"
UNPRIVILEGED_DEFAULT="1"
ONBOOT_DEFAULT="1"
NESTING_DEFAULT="1"
TIMEZONE_DEFAULT="Europe/Berlin"

DB_NAME="doodlenote"
DB_USER="doodlenote"
# Hinweis: die systemd-Unit ist unten im Inner-Setup eingebettet
# (identisch zu assets/doodle-note.service); kein Extra-Download nötig.

# CLI-Overrides: --ctid 101 --hostname doodle-note --storage local-lvm --bridge vmbr0 --net dhcp
CTID_ARG=""
HOSTNAME_ARG=""
STORAGE_ARG=""
BRIDGE_ARG=""
NET_ARG=""

# ============================================================================
# Debug / Logging / Fehlerkette
# ============================================================================
if [[ "${DEBUG:-0}" == "1" ]]; then
  set -x
fi

log_info() { echo -e "\e[34m[INFO]\e[0m $*"; }
log_ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
log_warn() { echo -e "\e[33m[WARN]\e[0m $*" >&2; }
log_err()  { echo -e "\e[31m[ERR]\e[0m $*" >&2; }

# Vollständige Fehlermeldungskette: Exit-Code, Kommando, Zeile, Stack, Hinweis auf bash -x.
err_trap() {
  local exit_code=$?
  local failed_cmd="${BASH_COMMAND:-unbekannt}"
  log_err "FEHLER: Installation abgebrochen."
  log_err "  Exit-Code : ${exit_code}"
  log_err "  Kommando  : ${failed_cmd}"
  log_err "  Stacktrace (neuester Aufruf zuerst):"
  local i=0
  while caller $i 2>/dev/null; do
    i=$((i + 1))
  done >&2 || true
  log_err "  Hinweis: Für das volle Ablaufprotokoll erneut mit bash -x starten:"
  log_err "    DEBUG=1 bash -x install/doodle-note.sh"
  log_err "  Container-Logs (falls CT existiert): pct exec <CTID> -- journalctl -u ${APP_NAME} -n 100 --no-pager"
}
trap err_trap ERR

die() {
  log_err "$*"
  exit 1
}

usage() {
  cat <<EOF
${APP_NAME} Proxmox-Installer

Auf dem Proxmox-Host als root ausführen:
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DoodleNoteProxmox/main/install/doodle-note.sh)"

Optionen:
  --ctid ID          Container-ID (Standard: nächste freie ab 100)
  --hostname NAME    Hostname (Standard: ${HOSTNAME_DEFAULT})
  --storage NAME     Storage für rootfs (Standard: ${STORAGE_DEFAULT})
  --bridge NAME      Bridge (Standard: ${BRIDGE_DEFAULT})
  --net NET          dhcp oder statisch, z. B. 10.0.0.50/24,gw=10.0.0.1 (Standard: ${NET_DEFAULT})
  -h, --help         Diese Hilfe

Umgebung:
  DEBUG=1            Ausführliches Tracing (set -x)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID_ARG="${2:-}"; shift 2 ;;
    --hostname) HOSTNAME_ARG="${2:-}"; shift 2 ;;
    --storage) STORAGE_ARG="${2:-}"; shift 2 ;;
    --bridge) BRIDGE_ARG="${2:-}"; shift 2 ;;
    --net) NET_ARG="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

CTID="${CTID_ARG:-${CTID_DEFAULT}}"
HOSTNAME="${HOSTNAME_ARG:-${HOSTNAME_DEFAULT}}"
STORAGE="${STORAGE_ARG:-${STORAGE_DEFAULT}}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE_DEFAULT}"
BRIDGE="${BRIDGE_ARG:-${BRIDGE_DEFAULT}}"
NET_CFG="${NET_ARG:-${NET_DEFAULT}}"

# ============================================================================
# Host-Prüfungen
# ============================================================================
[[ "$(id -u)" -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
command -v pct >/dev/null 2>&1 || die "pct nicht gefunden — kein Proxmox-Host?"
command -v pveam >/dev/null 2>&1 || die "pveam nicht gefunden — kein Proxmox-Host?"
command -v openssl >/dev/null 2>&1 || die "openssl fehlt auf dem Host."
command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || die "weder wget noch curl auf dem Host gefunden."

next_free_ctid() {
  local id=100
  while pct status "$id" >/dev/null 2>&1; do
    id=$((id + 1))
  done
  echo "$id"
}

if [[ -z "$CTID" ]]; then
  CTID="$(next_free_ctid)"
  log_info "Keine CTID angegeben — nutze nächste freie ID: ${CTID}"
fi
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige CTID: ${CTID}"

container_exists() { pct status "$1" >/dev/null 2>&1; }

# Idempotenz: Existiert der CT bereits mit fertiger App, wird Update statt Neuinstallation gefahren.
if container_exists "$CTID"; then
  if pct exec "$CTID" -- test -d "${APP_DIR}/.git" 2>/dev/null; then
    log_warn "CT ${CTID} existiert bereits mit ${APP_DIR} — fahre Update-Pfad (git pull + rebuild)."
    UPDATE_MODE="1"
  else
    die "CTID ${CTID} ist bereits vergeben (pct status ok), enthält aber keine ${APP_NAME}-Installation. Andere ID via --ctid wählen oder CT entfernen: pct stop ${CTID} && pct destroy ${CTID}"
  fi
else
  UPDATE_MODE="0"
fi

# ============================================================================
# Template sicherstellen
# ============================================================================
ensure_template() {
  log_info "Aktualisiere Template-Liste (pveam update) ..."
  pveam update 2>&1 | tail -n 5
  if pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE_DEFAULT}"; then
    log_ok "Template ${TEMPLATE_DEFAULT} bereits vorhanden."
    return 0
  fi
  # Fallback: neuestes debian-12-standard Template nehmen
  local avail
  avail="$(pveam available --section system 2>/dev/null | grep -o 'debian-12-standard_[^ ]*amd64.tar.zst' | sort -u | tail -n 1 || true)"
  if [[ -n "$avail" ]]; then
    TEMPLATE_DEFAULT="$avail"
    log_info "Nutze verfügbares Template: ${TEMPLATE_DEFAULT}"
  fi
  if ! pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | grep -q "${TEMPLATE_DEFAULT}"; then
    log_info "Lade Template ${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_DEFAULT} ..."
    pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE_DEFAULT}"
  fi
  log_ok "Template bereit: ${TEMPLATE_DEFAULT}"
}

# ============================================================================
# Container erstellen / starten
# ============================================================================
create_container() {
  local net0
  if [[ "$NET_CFG" == "dhcp" ]]; then
    net0="name=eth0,bridge=${BRIDGE},ip=dhcp"
  else
    net0="name=eth0,bridge=${BRIDGE},ip=${NET_CFG}"
  fi
  log_info "Erstelle LXC ${CTID} (${HOSTNAME}, ${CPU_DEFAULT}vCPU/${RAM_DEFAULT}MB/${DISK_DEFAULT}G, ${STORAGE}) ..."
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_DEFAULT}" \
    --hostname "$HOSTNAME" \
    --cores "$CPU_DEFAULT" \
    --memory "$RAM_DEFAULT" \
    --rootfs "${STORAGE}:${DISK_DEFAULT}" \
    --net0 "$net0" \
    --unprivileged "$UNPRIVILEGED_DEFAULT" \
    --features "nesting=${NESTING_DEFAULT}" \
    --onboot "$ONBOOT_DEFAULT" \
    --timezone "$TIMEZONE_DEFAULT" \
    --tags "$APP_NAME" \
    --start 0
  log_ok "Container ${CTID} erstellt (onboot=${ONBOOT_DEFAULT})."
}

start_container() {
  local state
  state="$(pct status "$CTID" 2>/dev/null | awk '{print $2}' || echo unknown)"
  if [[ "$state" != "running" ]]; then
    log_info "Starte CT ${CTID} ..."
    pct start "$CTID"
  fi
  log_info "Warte auf CT-Boot ..."
  for _ in $(seq 1 30); do
    sleep 2
    if pct exec "$CTID" -- true 2>/dev/null; then
      log_ok "CT ${CTID} reagiert auf pct exec."
      return 0
    fi
  done
  pct status "$CTID" || true
  die "CT ${CTID} bootet nicht (pct exec nach 60s ohne Antwort)."
}

get_ct_ip() {
  local ip=""
  for _ in $(seq 1 30); do
    ip="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    sleep 2
  done
  log_warn "Keine CT-IP via hostname -I ermittelbar (evtl. noch DHCP). Nutze Fallback für BETTER_AUTH_URL."
  echo ""
}

# ============================================================================
# Inneres Setup-Script (läuft IM Container via pct exec) — idempotent
# ============================================================================
run_inner_setup() {
  local ct_ip="$1"
  local inner_tmp
  inner_tmp="$(mktemp /tmp/doodle-note-inner.XXXXXX.sh)"

  cat > "$inner_tmp" <<INNER_EOF
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME}"
WEB_PORT="${WEB_PORT}"
APP_DIR="${APP_DIR}"
ENV_DIR="${ENV_DIR}"
ENV_FILE="${ENV_FILE}"
UPSTREAM_REPO="${UPSTREAM_REPO}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
CT_IP="${ct_ip}"

log()  { echo -e "\e[34m[CT-INFO]\e[0m \$*"; }
ok()   { echo -e "\e[32m[CT-OK]\e[0m \$*"; }
warn() { echo -e "\e[33m[CT-WARN]\e[0m \$*" >&2; }

ct_err() {
  local code=\$?
  echo -e "\e[31m[CT-ERR]\e[0m Fehler im Container-Setup." >&2
  echo -e "\e[31m[CT-ERR]\e[0m   Exit-Code: \${code}" >&2
  echo -e "\e[31m[CT-ERR]\e[0m   Kommando : \${BASH_COMMAND:-unbekannt}" >&2
  echo -e "\e[31m[CT-ERR]\e[0m   Stack:" >&2
  local i=0
  while caller \$i 2>/dev/null; do i=\$((i+1)); done >&2 || true
}
trap ct_err ERR

export DEBIAN_FRONTEND=noninteractive

log "OS-Pakete installieren ..."
apt-get update
apt-get install -y ca-certificates curl git openssl postgresql postgresql-contrib build-essential python3 sudo
systemctl enable --now postgresql
ok "Basis + Postgres installiert."

log "Node.js 22 sicherstellen ..."
NEED_NODE="1"
if command -v node >/dev/null 2>&1; then
  MAJOR="\$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [[ "\${MAJOR}" -ge 22 ]]; then NEED_NODE="0"; log "Node \$(node -v) bereits ok."; fi
fi
if [[ "\${NEED_NODE}" == "1" ]]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
node -v
npm -v

log "pnpm 10.33.2 via corepack ..."
corepack enable
corepack prepare pnpm@10.33.2 --activate
pnpm -v
ok "Node/pnpm bereit."

log "Postgres-Rolle/DB (idempotent) ..."
DB_PASS="\$(openssl rand -hex 24)"
if ! su postgres -c "psql -tAc \\"SELECT 1 FROM pg_roles WHERE rolname='\${DB_USER}'\\"" | grep -q 1; then
  su postgres -c "psql -c \\"CREATE USER \${DB_USER} WITH PASSWORD '\${DB_PASS}' CREATEDB;\\""
  STORED_PASS="\${DB_PASS}"
else
  su postgres -c "psql -c \\"ALTER USER \${DB_USER} WITH PASSWORD '\${DB_PASS}';\\""
  STORED_PASS="\${DB_PASS}"
fi
if ! su postgres -c "psql -lqt" | cut -d'|' -f1 | grep -qw "\${DB_NAME}"; then
  su postgres -c "createdb -O \${DB_USER} \${DB_NAME}"
fi
su postgres -c "psql -c \\"GRANT ALL PRIVILEGES ON DATABASE \${DB_NAME} TO \${DB_USER};\\""
echo "\${STORED_PASS}" > "\${ENV_DIR:-/etc/doodle-note}/.dbpass"
chmod 600 "\${ENV_DIR:-/etc/doodle-note}/.dbpass" 2>/dev/null || (mkdir -p /etc/doodle-note && echo "\${STORED_PASS}" > /etc/doodle-note/.dbpass && chmod 600 /etc/doodle-note/.dbpass)
ok "Postgres-DB \${DB_NAME} / User \${DB_USER} bereit."

log "App-Code synchronisieren (\${UPSTREAM_REPO} @ \${UPSTREAM_BRANCH}) ..."
if [[ -d "\${APP_DIR}/.git" ]]; then
  git -C "\${APP_DIR}" fetch origin
  git -C "\${APP_DIR}" checkout "\${UPSTREAM_BRANCH}"
  git -C "\${APP_DIR}" pull --ff-only origin "\${UPSTREAM_BRANCH}" || warn "git pull nicht fast-forward — lokaler Stand bleibt, weiter mit Build."
else
  rm -rf "\${APP_DIR}"
  git clone --branch "\${UPSTREAM_BRANCH}" --depth 1 "\${UPSTREAM_REPO}" "\${APP_DIR}"
fi
git -C "\${APP_DIR}" rev-parse --short HEAD
ok "App-Code aktuell."

log "Umgebungsdatei \${ENV_FILE} schreiben (Secrets bleiben bei Re-Run erhalten) ..."
mkdir -p "\${ENV_DIR}"
chmod 700 "\${ENV_DIR}"
KEEP_SECRET=""
if [[ -f "\${ENV_FILE}" ]]; then
  KEEP_SECRET="\$(grep -E '^BETTER_AUTH_SECRET=' "\${ENV_FILE}" | cut -d= -f2- || true)"
fi
if [[ -z "\${KEEP_SECRET}" ]]; then KEEP_SECRET="\$(openssl rand -hex 32)"; fi
KEEP_DB_URL=""
if [[ -f "\${ENV_FILE}" ]]; then
  KEEP_DB_URL="\$(grep -E '^DATABASE_URL=' "\${ENV_FILE}" | cut -d= -f2- || true)"
fi
DBPASS="\$(cat /etc/doodle-note/.dbpass)"
if [[ -z "\${KEEP_DB_URL}" ]]; then
  KEEP_DB_URL="postgres://\${DB_USER}:\${DBPASS}@localhost:5432/\${DB_NAME}"
fi
if [[ -n "\${CT_IP}" ]]; then AUTH_URL="http://\${CT_IP}:\${WEB_PORT}"; else AUTH_URL="http://localhost:\${WEB_PORT}"; fi
cat > "\${ENV_FILE}" <<ENVINNER
# DoodleNote self-hosted (Proxmox-LXC) — generiert, Secrets nicht committen
NODE_ENV=production
DOODLENOTE_SELF_HOSTED=true
PORT=\${WEB_PORT}
DATABASE_URL=\${KEEP_DB_URL}
BETTER_AUTH_URL=\${AUTH_URL}
BETTER_AUTH_SECRET=\${KEEP_SECRET}
ENVINNER
chmod 600 "\${ENV_FILE}"
ok "Env-Datei geschrieben (BETTER_AUTH_URL=\${AUTH_URL})."

log "Abhängigkeiten installieren (pnpm --frozen-lockfile, kann einige Minuten dauern) ..."
cd "\${APP_DIR}"
pnpm install --frozen-lockfile
ok "pnpm install fertig."

log "Drizzle-Migration (Postgres) ..."
set +e
MIG_OUT="\$(DATABASE_URL="\${KEEP_DB_URL}" pnpm --filter @repo/db exec drizzle-kit migrate 2>&1)"
MIG_CODE=\$?
set -e
echo "\${MIG_OUT}" | tail -n 30
if [[ \${MIG_CODE} -ne 0 ]]; then
  warn "drizzle-kit migrate meldete Exit \${MIG_CODE} — prüfe, ob Tabellen bereits existieren; Build läuft trotzdem weiter. Volle Ausgabe oben."
else
  ok "Migration ok."
fi

log "Produktions-Build (apps/web) ..."
pnpm --filter web build
ok "Build fertig."

log "systemd-Unit installieren ..."
cat > /etc/systemd/system/\${APP_NAME}.service <<'UNITEOF'
[Unit]
Description=DoodleNote Web Workspace (Next.js Sync Server)
Documentation=https://github.com/Onyx-Dev-Labs/doodle-note/blob/main/SELF-HOSTING.md
After=network-online.target postgresql.service
Wants=network-online.target postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/doodle-note
EnvironmentFile=/etc/doodle-note/doodle-note.env
ExecStart=/usr/bin/pnpm --filter web start
Restart=always
RestartSec=5
TimeoutStopSec=30
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
UNITEOF
PNPM_BIN="\$(command -v pnpm)"
if [[ "\${PNPM_BIN}" != "/usr/bin/pnpm" ]]; then
  log "pnpm liegt unter \${PNPM_BIN} — passe ExecStart an."
  sed -i "s|^ExecStart=/usr/bin/pnpm|ExecStart=\${PNPM_BIN}|" /etc/systemd/system/\${APP_NAME}.service
fi
systemctl daemon-reload
systemctl enable "\${APP_NAME}"
systemctl restart "\${APP_NAME}"
ok "systemd-Unit aktiv."

log "Verifikation im Container ..."
systemctl is-active "\${APP_NAME}" || { systemctl status "\${APP_NAME}" --no-pager || true; journalctl -u "\${APP_NAME}" -n 100 --no-pager || true; echo "Service läuft nicht." >&2; exit 1; }
for i in \$(seq 1 30); do
  if curl -fsS -o /dev/null "http://localhost:\${WEB_PORT}/" 2>&1; then
    ok "Web UI antwortet auf localhost:\${WEB_PORT}."
    exit 0
  fi
  sleep 2
done
echo "Web UI antwortet nicht auf localhost:\${WEB_PORT}." >&2
systemctl status "\${APP_NAME}" --no-pager >&2 || true
journalctl -u "\${APP_NAME}" -n 100 --no-pager >&2 || true
ss -ltnp 2>/dev/null >&2 || netstat -ltnp 2>/dev/null >&2 || true
exit 1
INNER_EOF

  log_info "Übertrage Setup in CT ${CTID} und führe aus (dauert mehrere Minuten) ..."
  pct push "$CTID" "$inner_tmp" /tmp/doodle-note-inner.sh
  # Volles Log am Host sichtbar; bei Fehler greift der ERR-Trap mit Kette.
  pct exec "$CTID" -- bash /tmp/doodle-note-inner.sh
  local code=$?
  rm -f "$inner_tmp"
  return "$code"
}

# ============================================================================
# Ablauf
# ============================================================================
log_info "=== ${APP_NAME} Proxmox-Installer (Host: $(hostname)) ==="
if [[ "$UPDATE_MODE" == "0" ]]; then
  ensure_template
  create_container
fi
start_container
CT_IP="$(get_ct_ip || true)"
if [[ -n "$CT_IP" ]]; then
  log_info "Container-IP: ${CT_IP}"
else
  log_warn "Container-IP unbekannt — BETTER_AUTH_URL nutzt localhost-Fallback."
fi

run_inner_setup "$CT_IP"

log_info "Host-seitige Verifikation ..."
pct exec "$CTID" -- systemctl is-active "$APP_NAME"
for _ in $(seq 1 10); do
  if pct exec "$CTID" -- curl -fsS -o /dev/null "http://localhost:${WEB_PORT}/" 2>/dev/null; then
    break
  fi
  sleep 2
done
pct exec "$CTID" -- curl -fsSI "http://localhost:${WEB_PORT}/" 2>&1 | head -n 5
# onboot sicherstellen (reboot-sicher)
pct set "$CTID" --onboot 1
log_ok "onboot=1 gesetzt (CT startet nach Host-Reboot automatisch)."

FINAL_IP="${CT_IP:-<CT-IP>}"
if [[ "$FINAL_IP" == "<CT-IP>" ]]; then
  FINAL_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo '<CT-IP>')"
fi

cat <<EOF

========================================
 ${APP_NAME} Installation erfolgreich
========================================
 Container : CT ${CTID} (${HOSTNAME})
 Web UI    : http://${FINAL_IP}:${WEB_PORT}
 Lokaltest : pct exec ${CTID} -- curl -I http://localhost:${WEB_PORT}/
 Service   : pct exec ${CTID} -- systemctl status ${APP_NAME}
 Update    : Script erneut laufen lassen (idempotent, --ctid ${CTID})
 Reboot-Test: pct reboot ${CTID} && sleep 15 && pct exec ${CTID} -- systemctl is-active ${APP_NAME}
========================================
 Hinweis: Desktop-Capture/Transkription läuft weiterhin nur auf macOS/Windows.
 Dieser LXC stellt den selbstgehosteten Sync-Server (apps/web).
EOF
log_ok "Fertig."
