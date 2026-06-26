#!/bin/bash
set -e

XRAY_CONFIG="/etc/xray/config.json"
PROFILES_DIR="/etc/xray/profiles"
PUBKEY_FILE="/etc/xray/reality-public-key"
FINGERPRINT_FILE="/etc/xray/fingerprint"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "This script must be run as root."
}

require_deps() {
  for cmd in jq docker curl openssl; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
  done
}

get_server_ip() {
  curl -4 -s --max-time 5 ifconfig.me || die "Could not detect server IP."
}

get_public_key() {
  [ -f "$PUBKEY_FILE" ] || die "Reality public key not found at $PUBKEY_FILE. Run setup first."
  cat "$PUBKEY_FILE"
}

get_port() {
  jq -r '.inbounds[0].port' "$XRAY_CONFIG"
}

get_sni() {
  jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$XRAY_CONFIG" | cut -d: -f1
}

reload_xray() {
  echo "Reloading Xray..."
  docker restart xray >/dev/null
  sleep 2
  if docker ps | grep -q xray; then
    echo "Xray reloaded successfully."
  else
    echo "WARNING: Xray may not have started. Check: docker logs xray" >&2
  fi
}

backup_config() {
  local ts
  ts=$(date +%F-%T | tr ':' '_')
  cp -f "$XRAY_CONFIG" "${XRAY_CONFIG}.bak-${ts}" 2>/dev/null || true
  echo "Config backed up to ${XRAY_CONFIG}.bak-${ts}"
}

get_fingerprint() {
  [ -f "$FINGERPRINT_FILE" ] && cat "$FINGERPRINT_FILE" || echo "chrome"
}

build_vless_link() {
  local uuid="$1" name="$2" short_id="$3"
  local ip port pubkey sni fp
  ip=$(get_server_ip)
  port=$(get_port)
  pubkey=$(get_public_key)
  sni=$(get_sni)
  fp=$(get_fingerprint)
  echo "vless://${uuid}@${ip}:${port}?type=tcp&security=reality&pbk=${pubkey}&fp=${fp}&sni=${sni}&sid=${short_id}&flow=xtls-rprx-vision#${name}"
}

# ---------------------------------------------------------------------------
# setup — interactive first-time setup
# ---------------------------------------------------------------------------

cmd_setup() {
  require_root
  require_deps

  # Warn if profiles already exist — re-running setup generates new keys
  # and invalidates all existing VLESS links
  local existing_profiles
  existing_profiles=$(ls "$PROFILES_DIR"/*.json 2>/dev/null || true)
  if [ -n "$existing_profiles" ]; then
    echo "WARNING: existing profiles found:"
    echo "$existing_profiles" | xargs -I{} jq -r '.name' {} 2>/dev/null
    echo ""
    echo "Re-running setup generates NEW keys. All existing VLESS links will stop working"
    echo "and profile files will be deleted."
    printf "Continue anyway? [y/N] "
    read -r confirm
    case "$confirm" in
      [yY][eE][sS]|[yY]) rm -f "$PROFILES_DIR"/*.json ;;
      *) echo "Abort."; exit 0 ;;
    esac
  fi

  PORT=8443
  if ss -tlnp | grep -q ":$PORT "; then
    echo "Port $PORT is busy, using 2053."
    PORT=2053
  fi

  SNI="www.apple.com"
  FINGERPRINT="chrome"

  UUID=$(cat /proc/sys/kernel/random/uuid)
  KEYS=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null)
  PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | awk '{print $2}')
  PUBLIC_KEY=$(echo "$KEYS" | grep "(PublicKey)" | awk '{print $3}')
  SHORT_ID=$(openssl rand -hex 8)

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "ERROR: Failed to generate keys. x25519 output:"
    echo "$KEYS"
    exit 1
  fi

  SERVER_IP=$(curl -4 -s ifconfig.me)

  mkdir -p /etc/xray "$PROFILES_DIR"

  cat > "$XRAY_CONFIG" <<CONF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": []
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
  }],
  "outbounds": [{"protocol": "freedom"}]
}
CONF

  chmod 644 "$XRAY_CONFIG"
  echo "$PUBLIC_KEY" > "$PUBKEY_FILE"
  echo "$FINGERPRINT" > "$FINGERPRINT_FILE"

  docker rm -f xray 2>/dev/null && echo "Old container removed." || true
  docker run -d \
    --name xray \
    --restart unless-stopped \
    --network host \
    -v /etc/xray:/etc/xray \
    ghcr.io/xtls/xray-core:latest \
    run -c /etc/xray/config.json

  sleep 2

  if docker ps | grep -q xray; then
    echo ""
    echo "✓ Xray started on port $PORT"
    echo "  Server IP:  $SERVER_IP"
    echo "  SNI:        $SNI"
    echo "  Public Key: $PUBLIC_KEY"
    echo ""
    echo "Rollback: docker rm -f xray && rm -rf /etc/xray"
  else
    die "Container failed to start. Check logs: docker logs xray"
  fi

  echo ""
  read -rp "Create your first profile now? [y/N]: " create_ans
  case "$create_ans" in
    [yY][eE][sS]|[yY]) cmd_create "" ;;
    *) echo "Done. Use '$0 create <name>' to add profiles." ;;
  esac
}

# ---------------------------------------------------------------------------
# create [name]
# ---------------------------------------------------------------------------

cmd_create() {
  require_root
  require_deps

  local name="$1"
  if [ -z "$name" ]; then
    echo "Existing profiles:"
    ls "$PROFILES_DIR"/*.json 2>/dev/null | xargs -I{} jq -r '.name' {} 2>/dev/null || echo "  (none)"
    echo ""
    read -rp "Enter new profile name: " name
    [ -n "$name" ] || die "No name provided."
  fi

  mkdir -p "$PROFILES_DIR"
  local profile_file="$PROFILES_DIR/${name}.json"
  [ ! -f "$profile_file" ] || die "Profile '${name}' already exists."

  local uuid short_id created_at
  uuid=$(cat /proc/sys/kernel/random/uuid)
  short_id=$(openssl rand -hex 8)
  created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  backup_config

  local tmp_config
  tmp_config=$(mktemp)
  jq --arg uuid "$uuid" --arg sid "$short_id" \
     '.inbounds[0].settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision"}] |
      .inbounds[0].streamSettings.realitySettings.shortIds += [$sid]' \
     "$XRAY_CONFIG" > "$tmp_config"
  mv "$tmp_config" "$XRAY_CONFIG" && chmod 644 "$XRAY_CONFIG"

  cat > "$profile_file" <<PROFILE
{
  "name": "${name}",
  "uuid": "${uuid}",
  "short_id": "${short_id}",
  "created_at": "${created_at}",
  "note": ""
}
PROFILE

  reload_xray

  local link
  link=$(build_vless_link "$uuid" "$name" "$short_id")

  echo ""
  echo "=== Profile '${name}' created ==="
  echo "UUID:      $uuid"
  echo "Short ID:  $short_id"
  echo "Created:   $created_at"
  echo ""
  echo "=== VLESS Link ==="
  echo "$link"
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

cmd_list() {
  require_deps
  mkdir -p "$PROFILES_DIR"
  local profiles
  profiles=$(ls "$PROFILES_DIR"/*.json 2>/dev/null || true)

  if [ -z "$profiles" ]; then
    echo "No profiles found."
    return 0
  fi

  printf "%-20s %-38s %-20s %-8s\n" "NAME" "UUID" "CREATED AT" "ACTIVE"
  printf "%-20s %-38s %-20s %-8s\n" "----" "----" "----------" "------"

  for f in $profiles; do
    local pname puuid pdate active
    pname=$(jq -r '.name' "$f")
    puuid=$(jq -r '.uuid' "$f")
    pdate=$(jq -r '.created_at' "$f")
    if jq -e --arg uuid "$puuid" \
        '.inbounds[0].settings.clients[] | select(.id == $uuid)' \
        "$XRAY_CONFIG" >/dev/null 2>&1; then
      active="yes"
    else
      active="no"
    fi
    printf "%-20s %-38s %-20s %-8s\n" "$pname" "$puuid" "$pdate" "$active"
  done
}

# ---------------------------------------------------------------------------
# revoke [-y|--yes] <name>
# ---------------------------------------------------------------------------

cmd_revoke() {
  require_root
  require_deps

  local yes_flag=0 name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) yes_flag=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done

  [ -n "$name" ] || die "Usage: $0 revoke [-y|--yes] <name>"

  local profile_file="$PROFILES_DIR/${name}.json"
  [ -f "$profile_file" ] || die "Profile '${name}' not found."

  local uuid short_id
  uuid=$(jq -r '.uuid' "$profile_file")
  short_id=$(jq -r '.short_id' "$profile_file")

  if [ "$yes_flag" -eq 0 ]; then
    echo "You are about to revoke profile '${name}' (UUID: ${uuid})."
    printf "Continue? [y/N] "
    read -r response
    case $response in
      [yY][eE][sS]|[yY]) ;;
      *) echo "Abort. No changes made."; exit 0 ;;
    esac
  fi

  backup_config

  local tmp_config
  tmp_config=$(mktemp)
  jq --arg uuid "$uuid" --arg sid "$short_id" \
     '.inbounds[0].settings.clients = [.inbounds[0].settings.clients[] | select(.id != $uuid)] |
      .inbounds[0].streamSettings.realitySettings.shortIds = [.inbounds[0].streamSettings.realitySettings.shortIds[] | select(. != $sid)]' \
     "$XRAY_CONFIG" > "$tmp_config"
  mv "$tmp_config" "$XRAY_CONFIG" && chmod 644 "$XRAY_CONFIG"

  rm -f "$profile_file"
  reload_xray

  echo "Profile '${name}' revoked and removed."
}

# ---------------------------------------------------------------------------
# sync — re-add profile UUIDs missing from config
# ---------------------------------------------------------------------------

cmd_sync() {
  require_root
  require_deps

  local profiles fixed=0
  profiles=$(ls "$PROFILES_DIR"/*.json 2>/dev/null || true)

  if [ -z "$profiles" ]; then
    echo "No profiles found."
    return 0
  fi

  backup_config

  for f in $profiles; do
    local pname puuid psid
    pname=$(jq -r '.name' "$f")
    puuid=$(jq -r '.uuid' "$f")
    psid=$(jq -r '.short_id' "$f")

    if ! jq -e --arg uuid "$puuid" \
        '.inbounds[0].settings.clients[] | select(.id == $uuid)' \
        "$XRAY_CONFIG" >/dev/null 2>&1; then
      echo "Restoring: $pname"
      local tmp_config
      tmp_config=$(mktemp)
      jq --arg uuid "$puuid" --arg sid "$psid" \
         '.inbounds[0].settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision"}] |
          .inbounds[0].streamSettings.realitySettings.shortIds += [$sid]' \
         "$XRAY_CONFIG" > "$tmp_config"
      mv "$tmp_config" "$XRAY_CONFIG" && chmod 644 "$XRAY_CONFIG"
      fixed=$((fixed + 1))
    fi
  done

  if [ "$fixed" -eq 0 ]; then
    echo "All profiles are already active."
  else
    reload_xray
    echo "$fixed profile(s) restored."
  fi
}

# ---------------------------------------------------------------------------
# show <name>
# ---------------------------------------------------------------------------

cmd_show() {
  require_deps
  local name="$1"
  [ -n "$name" ] || die "Usage: $0 show <name>"

  local profile_file="$PROFILES_DIR/${name}.json"
  [ -f "$profile_file" ] || die "Profile '${name}' not found."

  local uuid short_id created_at active
  uuid=$(jq -r '.uuid' "$profile_file")
  short_id=$(jq -r '.short_id' "$profile_file")
  created_at=$(jq -r '.created_at' "$profile_file")
  active="no"
  if jq -e --arg uuid "$uuid" \
      '.inbounds[0].settings.clients[] | select(.id == $uuid)' \
      "$XRAY_CONFIG" >/dev/null 2>&1; then
    active="yes"
  fi

  local link
  link=$(build_vless_link "$uuid" "$name" "$short_id")

  echo "=== Profile '${name}' ==="
  echo "UUID:      $uuid"
  echo "Short ID:  $short_id"
  echo "Created:   $created_at"
  echo "Active:    $active"
  echo "Server:    $(get_server_ip):$(get_port)"
  echo "Pubkey:    $(get_public_key)"
  echo ""
  echo "=== VLESS Link ==="
  echo "$link"
}

# ---------------------------------------------------------------------------
# start — (re)launch the Xray container from existing config
# ---------------------------------------------------------------------------

cmd_start() {
  require_root
  require_deps
  [ -f "$XRAY_CONFIG" ] || die "No config found. Run '$0' first to set up Xray."

  if docker ps --format '{{.Names}}' | grep -q "^xray$"; then
    echo "Xray is already running."
    docker ps --filter name=xray --format "  Container: {{.ID}}  Status: {{.Status}}"
    exit 0
  fi

  docker rm -f xray 2>/dev/null || true

  docker run -d \
    --name xray \
    --restart unless-stopped \
    --network host \
    -v /etc/xray:/etc/xray \
    ghcr.io/xtls/xray-core:latest \
    run -c /etc/xray/config.json

  sleep 2

  if docker ps | grep -q xray; then
    echo "✓ Xray started on port $(get_port)"
  else
    die "Container failed to start. Check logs: docker logs xray"
  fi
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

COMMAND="${1:-}"
shift 2>/dev/null || true

case "$COMMAND" in
  start)
    cmd_start
    ;;
  create)
    cmd_create "$@"
    ;;
  list)
    cmd_list
    ;;
  sync)
    cmd_sync
    ;;
  revoke)
    cmd_revoke "$@"
    ;;
  show)
    cmd_show "$@"
    ;;
  "")
    if [ ! -f "$XRAY_CONFIG" ]; then
      echo "Xray not configured. Starting interactive setup..."
      echo ""
      cmd_setup
    else
      echo "Usage: $0 <command> [args]"
      echo ""
      echo "Commands:"
      echo "  start                — (Re)launch the Xray container from existing config"
      echo "  create [name]        — Create a new profile (interactive if name omitted)"
    echo "  sync                 — Restore profiles missing from config"
      echo "  list                 — List all profiles with status"
      echo "  revoke [-y] <name>   — Revoke a profile (asks for confirmation unless -y)"
      echo "  show <name>          — Show details and VLESS link for a profile"
    fi
    ;;
  *)
    die "Unknown command: $COMMAND. Run '$0' for usage."
    ;;
esac
