#!/usr/bin/env bash
set -euo pipefail

# 3x-ui node setup script
# - Cloudflare API is used only for DNS A records.
# - 3x-ui installer handles panel SSL through its own normal installer/menu flow.
# - API token, panel port, and panel path are read from /etc/x-ui/install-result.env.
# - Creates a VLESS REALITY inbound on port 443 through the 3x-ui API.

DEFAULT_DOMAIN_ROOT="site.com"
VPN_PORT="443"
FALLBACK_PORT="8443"
REALITY_TARGET="www.cloudflare.com:443"
REALITY_SNI="www.cloudflare.com"
REALITY_FP="chrome"
INSTALL_ENV="/etc/x-ui/install-result.env"

ask_required() {
  local prompt="$1"
  local value=""
  while [ -z "$value" ]; do
    read -rp "$prompt: " value
  done
  printf '%s' "$value"
}

ask_optional() {
  local prompt="$1"
  local default_value="$2"
  local value=""
  read -rp "$prompt [$default_value]: " value
  printf '%s' "${value:-$default_value}"
}

ask_secret() {
  local prompt="$1"
  local value=""
  while [ -z "$value" ]; do
    read -rsp "$prompt: " value
    echo
  done
  printf '%s' "$value"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root."
    exit 1
  fi
}

install_packages() {
  echo "=== Installing packages ==="

  if command -v apt >/dev/null 2>&1; then
    apt update
    apt upgrade -y
    apt install -y curl wget tar gzip ca-certificates socat cron ufw jq dnsutils uuid-runtime openssl
    systemctl enable --now cron || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf update -y
    dnf install -y curl wget tar gzip ca-certificates socat cronie jq bind-utils util-linux openssl firewalld
    systemctl enable --now crond || true
  elif command -v yum >/dev/null 2>&1; then
    yum update -y
    yum install -y curl wget tar gzip ca-certificates socat cronie jq bind-utils util-linux openssl firewalld
    systemctl enable --now crond || true
  else
    echo "ERROR: unsupported OS. Need apt, dnf, or yum."
    exit 1
  fi

  timedatectl set-ntp true || true
}

get_public_ip() {
  local ip=""
  ip="$(curl -4 -fsSL https://api.ipify.org || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4 -fsSL https://ifconfig.me || true)"
  fi

  if [ -z "$ip" ]; then
    echo "ERROR: could not detect public IPv4."
    exit 1
  fi

  printf '%s' "$ip"
}

cloudflare_api() {
  local method="$1"
  local url="$2"
  local data="${3:-}"

  if [ -n "$data" ]; then
    curl -fsSL -X "$method" "$url" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -fsSL -X "$method" "$url" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

detect_cloudflare_zone_id() {
  if [ -n "${CF_ZONE_ID:-}" ]; then
    printf '%s' "$CF_ZONE_ID"
    return 0
  fi

  echo "=== Detecting Cloudflare Zone ID ===" >&2
  local zone_id
  zone_id="$(cloudflare_api GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN_ROOT}" | jq -r '.result[0].id // empty')"

  if [ -z "$zone_id" ]; then
    echo "ERROR: could not auto-detect Cloudflare Zone ID for ${DOMAIN_ROOT}." >&2
    exit 1
  fi

  printf '%s' "$zone_id"
}

cf_upsert_a_record() {
  local record_name="$1"
  local record_ip="$2"

  echo "Upserting DNS A record: ${record_name} -> ${record_ip}"

  local existing record_id payload result success
  existing="$(cloudflare_api GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${record_name}")"
  record_id="$(echo "$existing" | jq -r '.result[0].id // empty')"

  payload="$(
    jq -n \
      --arg record_type "A" \
      --arg record_name "$record_name" \
      --arg record_content "$record_ip" \
      '{
        type: $record_type,
        name: $record_name,
        content: $record_content,
        ttl: 120,
        proxied: false
      }'
  )"

  if [ -n "$record_id" ]; then
    result="$(cloudflare_api PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$payload")"
  else
    result="$(cloudflare_api POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" "$payload")"
  fi

  success="$(echo "$result" | jq -r '.success // false')"
  if [ "$success" != "true" ]; then
    echo "ERROR: Cloudflare DNS update failed for ${record_name}."
    echo "$result" | jq .
    exit 1
  fi

  echo "Cloudflare DNS update success: ${record_name}"
}

configure_firewall() {
  local panel_port="$1"

  echo "=== Configuring firewall ==="

  if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow "${panel_port}/tcp"
    ufw allow "${VPN_PORT}/tcp"
    ufw allow "${FALLBACK_PORT}/tcp"
    ufw --force enable
    ufw status
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    systemctl enable --now firewalld || true
    firewall-cmd --permanent --add-port=22/tcp || true
    firewall-cmd --permanent --add-port=80/tcp || true
    firewall-cmd --permanent --add-port="${panel_port}/tcp" || true
    firewall-cmd --permanent --add-port="${VPN_PORT}/tcp" || true
    firewall-cmd --permanent --add-port="${FALLBACK_PORT}/tcp" || true
    firewall-cmd --reload || true
    firewall-cmd --list-ports || true
    return 0
  fi

  echo "WARNING: no supported firewall tool found. Configure provider firewall manually."
}

run_xui_installer() {
  echo "=== Installing 3x-ui ==="
  echo "Answer the 3x-ui installer questions normally."
  echo "For SSL/domain, use panel domain only: ${PANEL_DOMAIN}"
  echo "Do not use VPN domain there: ${NODE_DOMAIN}"
  echo

  if command -v x-ui >/dev/null 2>&1; then
    echo "x-ui already installed. Skipping install."
  else
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
  fi

  systemctl restart x-ui || x-ui restart || true
  sleep 3
  x-ui status || true
}

load_xui_install_env() {
  echo "=== Reading x-ui install result ==="

  if [ ! -f "$INSTALL_ENV" ]; then
    echo "ERROR: ${INSTALL_ENV} not found."
    echo "Your 3x-ui install did not create install-result.env."
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$INSTALL_ENV"
  set +a

  PANEL_PORT="${XUI_PANEL_PORT:-}"
  PANEL_PATH="${XUI_WEB_BASE_PATH:-}"
  API_TOKEN="${XUI_API_TOKEN:-}"

  if [ -z "$PANEL_PORT" ] || [ -z "$PANEL_PATH" ] || [ -z "$API_TOKEN" ]; then
    echo "ERROR: missing XUI_PANEL_PORT, XUI_WEB_BASE_PATH, or XUI_API_TOKEN in ${INSTALL_ENV}."
    exit 1
  fi

  if [[ "$PANEL_PATH" != /* ]]; then
    PANEL_PATH="/${PANEL_PATH}"
  fi
  if [[ "$PANEL_PATH" != */ ]]; then
    PANEL_PATH="${PANEL_PATH}/"
  fi

  echo "Detected panel port: ${PANEL_PORT}"
  echo "Detected panel path: ${PANEL_PATH}"
  echo "Detected API token: yes"
}

xui_api() {
  local endpoint="$1"
  local data="${2:-}"
  local url="https://127.0.0.1:${PANEL_PORT}${PANEL_PATH}${endpoint}"

  if [ -n "$data" ]; then
    curl -k -sS "$url" \
      -H "Host: ${PANEL_DOMAIN}" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data-raw "$data"
  else
    curl -k -sS "$url" \
      -H "Host: ${PANEL_DOMAIN}" \
      -H "Authorization: Bearer ${API_TOKEN}"
  fi
}

test_xui_api() {
  echo "=== Testing x-ui API token ==="

  local api_test success
  api_test="$(xui_api "panel/api/inbounds/list")"
  success="$(echo "$api_test" | jq -r '.success // false')"

  if [ "$success" != "true" ]; then
    echo "ERROR: x-ui API token test failed."
    echo "$api_test" | jq .
    exit 1
  fi

  echo "x-ui API token works."
}

generate_reality_keys() {
  echo "=== Generating REALITY keys ==="

  local xray_bin key_output
  xray_bin="/usr/local/x-ui/bin/xray-linux-amd64"
  if [ ! -x "$xray_bin" ]; then
    xray_bin="/usr/local/x-ui/bin/xray"
  fi

  if [ ! -x "$xray_bin" ]; then
    echo "ERROR: xray binary not found."
    exit 1
  fi

  key_output="$($xray_bin x25519)"
  PRIVATE_KEY="$(echo "$key_output" | grep -E 'PrivateKey:|Private key:' | awk '{print $2}' | head -1)"
  PUBLIC_KEY="$(echo "$key_output" | grep -E 'Password \(PublicKey\):|Public key:' | awk '{print $2}' | head -1)"

  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "ERROR: could not generate REALITY keys."
    echo "$key_output"
    exit 1
  fi

  SHORT_ID="$(openssl rand -hex 2)"
  SPIDER_X="/$(openssl rand -hex 8)"

  echo "Public key: ${PUBLIC_KEY}"
  echo "Short ID:   ${SHORT_ID}"
  echo "SpiderX:    ${SPIDER_X}"
}

create_reality_inbound() {
  echo "=== Creating VLESS REALITY inbound ==="

  local existing_id settings_json stream_json sniffing_json add_body add_result add_success
  existing_id="$(
    xui_api "panel/api/inbounds/list" \
    | jq -r --arg remark "$INBOUND_REMARK" '.obj[]? | select(.remark==$remark) | .id' \
    | head -1
  )"

  if [ -n "$existing_id" ]; then
    echo "Inbound already exists: ${INBOUND_REMARK}, id=${existing_id}"
    echo "Skipping inbound creation."
    return 0
  fi

  settings_json="$(jq -nc '{clients:[], decryption:"none"}')"

  stream_json="$(
    jq -nc \
      --arg target "$REALITY_TARGET" \
      --arg sni "$REALITY_SNI" \
      --arg privateKey "$PRIVATE_KEY" \
      --arg shortId "$SHORT_ID" \
      '{
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false,
          target: $target,
          serverNames: [$sni],
          privateKey: $privateKey,
          shortIds: [$shortId],
          xver: 0
        },
        tcpSettings: {
          acceptProxyProtocol: false,
          header: { type: "none" }
        }
      }'
  )"

  sniffing_json="$(jq -nc '{enabled:false}')"

  add_body="$(
    jq -n \
      --arg remark "$INBOUND_REMARK" \
      --arg settings "$settings_json" \
      --arg streamSettings "$stream_json" \
      --arg sniffing "$sniffing_json" \
      --argjson port "$VPN_PORT" \
      '{
        up: 0,
        down: 0,
        total: 0,
        remark: $remark,
        enable: true,
        expiryTime: 0,
        listen: "0.0.0.0",
        port: $port,
        protocol: "vless",
        settings: $settings,
        streamSettings: $streamSettings,
        sniffing: $sniffing
      }'
  )"

  add_result="$(xui_api "panel/api/inbounds/add" "$add_body")"
  echo "$add_result" | jq .

  add_success="$(echo "$add_result" | jq -r '.success // false')"
  if [ "$add_success" != "true" ]; then
    echo "ERROR: failed to create inbound."
    exit 1
  fi
}

restart_and_check() {
  echo "=== Restarting x-ui ==="
  systemctl restart x-ui || x-ui restart || true
  sleep 3

  echo "=== Checking important ports ==="
  ss -lntp | grep -E ":80\\b|:${PANEL_PORT}\\b|:${VPN_PORT}\\b|:${FALLBACK_PORT}\\b" || true
}

write_info_file() {
  echo "=== Writing node info ==="

  mkdir -p /root/x-ui-backups
  cp -a /etc/x-ui "/root/x-ui-backups/${NODE_NAME}-after-auto-setup-$(date +%F-%H%M%S)" 2>/dev/null || true
  x-ui settings > "/root/x-ui-backups/${NODE_NAME}-settings-after-auto-setup-$(date +%F-%H%M%S).txt" 2>/dev/null || true

  cat >"/root/${NODE_NAME}-node-info.txt" <<EOF
NODE_NAME=${NODE_NAME}
NODE_DOMAIN=${NODE_DOMAIN}
PANEL_DOMAIN=${PANEL_DOMAIN}
PANEL_PORT=${PANEL_PORT}
PANEL_PATH=${PANEL_PATH}
VPN_PORT=${VPN_PORT}

REALITY_TARGET=${REALITY_TARGET}
REALITY_SNI=${REALITY_SNI}
REALITY_FINGERPRINT=${REALITY_FP}
REALITY_PUBLIC_KEY=${PUBLIC_KEY}
REALITY_SHORT_ID=${SHORT_ID}
REALITY_SPIDER_X=${SPIDER_X}

INBOUND_REMARK=${INBOUND_REMARK}

MASTER NODE SETTINGS:
Name: ${NODE_NAME}
Scheme: https
Address: ${PANEL_DOMAIN}
Port: ${PANEL_PORT}
Base path: ${PANEL_PATH}
API token: read from ${INSTALL_ENV} on this node

CLIENT / SUBSCRIPTION HOST MUST BE:
${NODE_DOMAIN}:${VPN_PORT}

REALITY CLIENT SETTINGS:
Address: ${NODE_DOMAIN}
Port: ${VPN_PORT}
Security: reality
Network: tcp
SNI: ${REALITY_SNI}
Fingerprint: ${REALITY_FP}
Public key: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}
SpiderX: ${SPIDER_X}
Flow: none / empty

IMPORTANT:
Panel/API domain: ${PANEL_DOMAIN}
Client/VPN domain: ${NODE_DOMAIN}
Do not use ${PANEL_DOMAIN} as the client address.
EOF

  echo
  echo "============================================================"
  echo "DONE"
  echo "============================================================"
  cat "/root/${NODE_NAME}-node-info.txt"
  echo "============================================================"
}

main() {
  require_root

  echo "============================================================"
  echo "3x-ui Auto Node Setup"
  echo "============================================================"

  NODE_NAME="$(ask_required 'Node name, example ca1 / ca2 / de3')"
  DOMAIN_ROOT="$(ask_optional 'Root domain' "$DEFAULT_DOMAIN_ROOT")"
  CF_TOKEN="$(ask_secret 'Cloudflare API token, used only for DNS')"
  read -rp "Cloudflare Zone ID, leave empty to auto-detect: " CF_ZONE_ID

  if ! [[ "$NODE_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
    echo "ERROR: invalid node name. Use only letters, numbers, dash."
    exit 1
  fi

  NODE_DOMAIN="${NODE_NAME}.${DOMAIN_ROOT}"
  PANEL_DOMAIN="${NODE_NAME}-panel.${DOMAIN_ROOT}"
  INBOUND_REMARK="${NODE_NAME^^}-REALITY-443"

  echo
  echo "Node name:     ${NODE_NAME}"
  echo "Root domain:   ${DOMAIN_ROOT}"
  echo "VPN domain:    ${NODE_DOMAIN}"
  echo "Panel domain:  ${PANEL_DOMAIN}"
  echo "VPN port:      ${VPN_PORT}"
  echo "Reality SNI:   ${REALITY_SNI}"
  echo

  install_packages

  PUBLIC_IP="$(get_public_ip)"
  echo "Public IP: ${PUBLIC_IP}"

  CF_ZONE_ID="$(detect_cloudflare_zone_id)"

  echo "=== Configuring Cloudflare DNS ==="
  cf_upsert_a_record "$NODE_DOMAIN" "$PUBLIC_IP"
  cf_upsert_a_record "$PANEL_DOMAIN" "$PUBLIC_IP"

  echo "=== DNS check ==="
  dig +short "$NODE_DOMAIN" || true
  dig +short "$PANEL_DOMAIN" || true

  echo "Before SSL step, make sure Cloudflare proxy is DNS-only for: ${PANEL_DOMAIN}"
  echo "The x-ui installer SSL step should use: ${PANEL_DOMAIN}"
  echo

  run_xui_installer
  load_xui_install_env
  configure_firewall "$PANEL_PORT"
  test_xui_api
  generate_reality_keys
  create_reality_inbound
  restart_and_check
  write_info_file
}

main "$@"
