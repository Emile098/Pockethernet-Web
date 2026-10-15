#!/usr/bin/env bash
# Create a Pocketweb LXC on a Proxmox VE host.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Emile098/Pockethernet-Web/cursor/one-line-proxmox-container-4e30/proxmox/pocketweb.sh)"
#
# The container serves the built site. Web Bluetooth still runs in the browser
# that opens the page, so the container does not need a Bluetooth adapter.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

POCKETWEB_REPO_DEFAULT="https://github.com/Emile098/Pockethernet-Web.git"
POCKETWEB_SCRIPT_URL="https://raw.githubusercontent.com/Emile098/Pockethernet-Web/cursor/one-line-proxmox-container-4e30/proxmox/pocketweb.sh"
POCKETWEB_IP="${POCKETWEB_IP:-}"
POCKETWEB_GW="${POCKETWEB_GW:-}"

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_RESET=""
fi

info() { printf '%s==>%s %s\n' "${C_GREEN:-}" "${C_RESET:-}" "$*" >&2; }
warn() { printf '%s==>%s %s\n' "${C_YELLOW:-}" "${C_RESET:-}" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "${C_RED:-}" "${C_RESET:-}" "$*" >&2
  exit 1
}

print_usage() {
  cat <<EOF
Usage: pocketweb.sh

Run this on a Proxmox VE host shell. It creates an unprivileged Debian LXC,
builds Pocketweb, and serves it with nginx.

  bash -c "\$(curl -fsSL ${POCKETWEB_SCRIPT_URL})"

Update an existing container:

  CTID=150 POCKETWEB_UPDATE=1 bash -c "\$(curl -fsSL ${POCKETWEB_SCRIPT_URL})"

Environment:
  CTID                       Container ID. Default: first free ID from 100.
  POCKETWEB_UPDATE           Set to 1 to rebuild inside an existing container.
  POCKETWEB_YES              Set to 1 to skip the confirmation prompt.
  POCKETWEB_HOSTNAME         Default: pocketweb
  POCKETWEB_CORES            Default: 2
  POCKETWEB_MEMORY           RAM in MB. Default: 2048. Minimum: 2048.
  POCKETWEB_DISK             Root disk in GB. Default: 8. Minimum: 8.
  POCKETWEB_BRIDGE           Default: vmbr0 when that bridge exists.
  POCKETWEB_STORAGE          Root filesystem storage. Default: local-lvm, then ZFS.
  POCKETWEB_TEMPLATE_STORAGE Storage that holds container templates. Default: local.
  POCKETWEB_TEMPLATE         Debian template file name. Default: newest 13, else 12.
  POCKETWEB_IP               dhcp, or a CIDR such as 192.168.1.50/24. Default: dhcp.
  POCKETWEB_GW               Gateway. Required when POCKETWEB_IP is static.
  POCKETWEB_IP6              Optional IPv6 value: auto, dhcp, or a CIDR.
  POCKETWEB_VLAN             Optional VLAN tag on the container NIC.
  POCKETWEB_HTTPS            1 (default) or 0. Web Bluetooth needs HTTPS off localhost.
  POCKETWEB_SOURCE           local when this script is inside a checkout, otherwise git.
  POCKETWEB_SRC              Checkout to install when the script is not inside it.
  POCKETWEB_REF              Git branch, tag, or commit. Default: main.
  POCKETWEB_REPO             HTTPS GitHub repository. Default: this project.
  POCKETWEB_TOKEN            GitHub token for a private git download. GH_TOKEN and
                             GITHUB_TOKEN are also read. Not stored in the container.
EOF
}

node_is_usable() {
  command -v node >/dev/null 2>&1 || return 1
  node -e 'const p=process.versions.node.split(".").map(Number); const ok=(p[0]===20&&p[1]>=19)||(p[0]===22&&p[1]>=12)||p[0]>22; if(!ok) process.exit(1);'
}

install_node() {
  if node_is_usable; then
    info "Using $(node -v)"
    return 0
  fi
  local arch sums name ver expected
  case "$(dpkg --print-architecture)" in
    amd64) arch="x64" ;;
    arm64) arch="arm64" ;;
    *) die "Unsupported architecture for Node.js: $(dpkg --print-architecture)" ;;
  esac
  sums="$(mktemp)"
  info "Downloading Node.js 22"
  curl -fsSL "https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt" -o "$sums"
  name="$(awk -v arch="$arch" '$2 ~ ("^node-v22\\.[0-9]+\\.[0-9]+-linux-" arch "\\.tar\\.xz$") { print $2; exit }' "$sums")"
  [[ -n "$name" ]] || die "Could not find a Node.js 22 Linux tarball"
  ver="${name#node-v}"
  ver="${ver%%-*}"
  awk -F. -v v="$ver" 'BEGIN { split(v, a, "."); if (!(a[1] > 22 || (a[1] == 22 && a[2] >= 12))) exit 1 }' \
    || die "Node.js ${ver} is older than 22.12"
  curl -fsSL "https://nodejs.org/dist/latest-v22.x/${name}" -o "/tmp/${name}"
  expected="$(awk -v file="$name" '$2 == file { print $1; exit }' "$sums")"
  [[ -n "$expected" ]] || die "Checksum for ${name} is missing"
  printf '%s  %s\n' "$expected" "$name" | (cd /tmp && sha256sum -c -)
  tar -xJf "/tmp/${name}" -C /usr/local --strip-components=1
  rm -f "/tmp/${name}" "$sums"
  hash -r
  node_is_usable || die "Node.js installed but does not meet the Vite engine requirement"
  info "Installed $(node -v)"
}

render_nginx_site() {
  local js="$1" css="$2" https="$3" prelude listen
  [[ "$js" =~ ^/assets/index-[A-Za-z0-9_-]+\.js$ ]] || die "Unexpected script path: ${js}"
  [[ "$css" =~ ^/assets/index-[A-Za-z0-9_-]+\.css$ ]] || die "Unexpected style path: ${css}"
  [[ "$https" == "0" || "$https" == "1" ]] || die "POCKETWEB_HTTPS must be 0 or 1"
  if [[ "$https" == "1" ]]; then
    prelude="$(cat <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}
EOF
)"
    listen="$(cat <<'EOF'
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_certificate /etc/nginx/ssl/pocketweb.crt;
    ssl_certificate_key /etc/nginx/ssl/pocketweb.key;
    ssl_protocols TLSv1.2 TLSv1.3;
EOF
)"
  else
    prelude=""
    listen="$(cat <<'EOF'
    listen 80 default_server;
    listen [::]:80 default_server;
EOF
)"
  fi
  cat <<EOF
# Generated by proxmox/pocketweb.sh.
${prelude}
server {
${listen}
    server_name _;
    root /opt/pocketweb/src/dist;
    index index.html;
    server_tokens off;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;

    location = /api/latest-version {
        proxy_pass https://ota.pockethernet.com/latest_version;
        proxy_ssl_server_name on;
        proxy_ssl_name ota.pockethernet.com;
        proxy_set_header Host ota.pockethernet.com;
        proxy_set_header Accept text/plain;
        proxy_connect_timeout 10s;
        proxy_read_timeout 20s;
        add_header Cache-Control "no-store" always;
        limit_except GET { deny all; }
    }

    location = /index.html {
        add_header Cache-Control "no-store";
    }

    location = ${js} {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location = ${css} {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location = /assets/logo.png {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location ~ ^/assets/index-.+\\.js\$ {
        add_header Cache-Control "no-store";
        try_files \$uri @pocketweb_current_js;
    }

    location @pocketweb_current_js {
        internal;
        add_header Cache-Control "no-store";
        root /opt/pocketweb/src/dist;
        try_files ${js} =404;
    }

    location ~ ^/assets/index-.+\\.css\$ {
        add_header Cache-Control "no-store";
        try_files \$uri @pocketweb_current_css;
    }

    location @pocketweb_current_css {
        internal;
        add_header Cache-Control "no-store";
        root /opt/pocketweb/src/dist;
        try_files ${css} =404;
    }

    location ~ ^/assets/logo-.+\\.png\$ {
        add_header Cache-Control "no-store";
        try_files \$uri @pocketweb_current_logo;
    }

    location @pocketweb_current_logo {
        internal;
        add_header Cache-Control "no-store";
        root /opt/pocketweb/src/dist;
        try_files /assets/logo.png =404;
    }

    location = /pockethernet-192.png {
        add_header Cache-Control "no-store";
        try_files /pockethernet-192.png /logo-192.png =404;
    }

    location = /pockethernet-512.png {
        add_header Cache-Control "no-store";
        try_files /pockethernet-512.png /logo-512.png =404;
    }

    location ~ ^/(sw\\.js|workbox-[A-Za-z0-9_-]+\\.js|manifest\\.webmanifest)\$ {
        add_header Cache-Control "no-store";
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
}

install_pocketweb() {
  local js css addr san scheme ip url attempt token
  : "${POCKETWEB_REPO:?}"
  : "${POCKETWEB_REF:?}"
  : "${POCKETWEB_SOURCE:?}"
  : "${POCKETWEB_HTTPS:?}"
  : "${POCKETWEB_HOSTNAME:?}"
  export DEBIAN_FRONTEND=noninteractive
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export npm_config_cache="/tmp/npm-cache"
  export npm_config_update_notifier=false
  export GIT_TERMINAL_PROMPT=0
  export NODE_OPTIONS="--max-old-space-size=1536"

  info "Waiting for DNS"
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if getent hosts deb.debian.org >/dev/null 2>&1; then
      break
    fi
    if ((attempt == 30)); then
      die "Container has no DNS for deb.debian.org"
    fi
    sleep 2
  done

  info "Installing packages"
  printf 'Acquire::Retries "5";\n' >/etc/apt/apt.conf.d/80-retries
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl xz-utils git nginx openssl
  install_node

  info "Fetching Pocketweb (${POCKETWEB_SOURCE})"
  rm -rf /opt/pocketweb/src
  mkdir -p /opt/pocketweb/src
  if [[ "$POCKETWEB_SOURCE" == "local" ]]; then
    [[ -n "${POCKETWEB_ARCHIVE:-}" && -f "$POCKETWEB_ARCHIVE" ]] || die "Local source archive is missing"
    tar -xzf "$POCKETWEB_ARCHIVE" -C /opt/pocketweb/src
  elif [[ "$POCKETWEB_SOURCE" == "git" ]]; then
    token=""
    if [[ -f /root/pocketweb-token ]]; then
      token="$(tr -d '[:space:]' </root/pocketweb-token)"
      rm -f /root/pocketweb-token
    fi
    git -C /opt/pocketweb/src init -q
    git -C /opt/pocketweb/src remote add origin "$POCKETWEB_REPO"
    if [[ -n "$token" ]]; then
      [[ "$token" =~ ^[A-Za-z0-9_]+$ ]] || die "GitHub token contains unsupported characters"
      git -C /opt/pocketweb/src -c "http.extraheader=AUTHORIZATION: bearer ${token}" \
        fetch --depth 1 origin "$POCKETWEB_REF" \
        || die "Could not fetch ${POCKETWEB_REF}. The GitHub token could not read ${POCKETWEB_REPO}."
      unset token
    else
      git -C /opt/pocketweb/src fetch --depth 1 origin "$POCKETWEB_REF" \
        || die "Could not fetch ${POCKETWEB_REF} from ${POCKETWEB_REPO}. Clone this private repo on the Proxmox host and run bash proxmox/pocketweb.sh from that checkout."
    fi
    git -C /opt/pocketweb/src checkout -q --detach FETCH_HEAD
  else
    die "POCKETWEB_SOURCE must be git or local"
  fi
  [[ -f /opt/pocketweb/src/package-lock.json ]] || die "Source is missing package-lock.json"

  cat >/opt/pocketweb/source.env <<EOF
source=${POCKETWEB_SOURCE}
repo=${POCKETWEB_REPO}
ref=${POCKETWEB_REF}
https=${POCKETWEB_HTTPS}
hostname=${POCKETWEB_HOSTNAME}
EOF

  info "Building Pocketweb"
  (
    cd /opt/pocketweb/src
    if [[ -d .git ]]; then
      git clean -fdx
    fi
    npm ci --no-audit --no-fund
    npm run build
  )
  [[ -f /opt/pocketweb/src/dist/index.html ]] || die "Build did not produce dist/index.html"
  js="$(grep -oE '/assets/index-[A-Za-z0-9_-]+\.js' /opt/pocketweb/src/dist/index.html | head -n 1)"
  css="$(grep -oE '/assets/index-[A-Za-z0-9_-]+\.css' /opt/pocketweb/src/dist/index.html | head -n 1)"
  [[ -n "$js" && -n "$css" ]] || die "Build output is missing hashed index.js or index.css"

  if [[ "$POCKETWEB_HTTPS" == "1" ]]; then
    info "Creating a local HTTPS certificate"
    install -d -m 0750 /etc/nginx/ssl
    san="DNS:${POCKETWEB_HOSTNAME},DNS:localhost,IP:127.0.0.1"
    for addr in $(hostname -I); do
      if [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$addr" =~ ^[0-9A-Fa-f:]+$ ]]; then
        san+=",IP:${addr}"
      fi
    done
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/pocketweb.key \
      -out /etc/nginx/ssl/pocketweb.crt \
      -days 825 \
      -subj "/CN=${POCKETWEB_HOSTNAME}" \
      -addext "subjectAltName=${san}"
    chgrp www-data /etc/nginx/ssl/pocketweb.key
    chmod 640 /etc/nginx/ssl/pocketweb.key
    chmod 644 /etc/nginx/ssl/pocketweb.crt
  fi

  info "Configuring nginx"
  render_nginx_site "$js" "$css" "$POCKETWEB_HTTPS" >/etc/nginx/sites-available/pocketweb
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
  ln -sfn /etc/nginx/sites-available/pocketweb /etc/nginx/sites-enabled/pocketweb
  nginx -t
  systemctl enable nginx || true
  if ! systemctl restart nginx; then
    service nginx restart
  fi

  scheme="https"
  [[ "$POCKETWEB_HTTPS" == "0" ]] && scheme="http"
  info "Checking the local page"
  curl -fsS -k --retry 5 --retry-connrefused --retry-delay 1 "${scheme}://127.0.0.1/" >/dev/null
  if ! curl -fsS -k --max-time 20 "${scheme}://127.0.0.1/api/latest-version" >/dev/null; then
    warn "Firmware version lookup did not respond. The page will still load."
  fi

  ip="$(hostname -I | awk '{ print $1 }')"
  [[ -n "$ip" ]] || die "Container has no IP address"
  url="${scheme}://${ip}/"
  printf '%s\n' "$url" >/opt/pocketweb/url
  cat >/etc/motd <<EOF
Pocketweb for Pockethernet
${url}

Web Bluetooth runs in the browser that opens this page.
Accept the local certificate once when HTTPS is enabled.
EOF
  rm -rf /opt/pocketweb/src/node_modules /tmp/npm-cache "${POCKETWEB_ARCHIVE:-}"
  info "Pocketweb is serving ${url}"
}

storage_names() {
  local content="$1" output status
  set +e
  output="$(pvesm status --content "$content" --enabled 1 2>/dev/null)"
  status=$?
  set -e
  if ((status != 0)); then
    output="$(pvesm status --content "$content")"
  fi
  awk 'NR > 1 && $3 == "active" { print $1 }' <<<"$output"
}

pick_template_storage() {
  local list="$1"
  [[ -n "$list" ]] || return 1
  if grep -Fxq "local" <<<"$list"; then
    printf '%s\n' "local"
    return 0
  fi
  head -n 1 <<<"$list"
}

pick_root_storage() {
  local list="$1" candidate
  [[ -n "$list" ]] || return 1
  for candidate in local-lvm local-zfs local-btrfs; do
    if grep -Fxq "$candidate" <<<"$list"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  candidate="$(grep -vx 'local' <<<"$list" | head -n 1 || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  head -n 1 <<<"$list"
}

next_ctid() {
  local id=100
  while [[ -f "/etc/pve/lxc/${id}.conf" || -f "/etc/pve/qemu-server/${id}.conf" ]]; do
    id=$((id + 1))
  done
  ((id <= 999999999)) || die "No free container ID"
  printf '%s\n' "$id"
}

normalize_mb() {
  local value="${1%[Bb]}"
  value="${value%[Mm]}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

normalize_disk_gb() {
  local value="${1%[Bb]}"
  value="${value%[Gg]}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

valid_ctid() {
  local id="$1"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  ((10#$id >= 100 && 10#$id <= 999999999))
}

valid_hostname() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

prompt_value() {
  local name="$1" label="$2" default="$3" current reply
  current="${!name:-}"
  if [[ -n "$current" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    printf -v "$name" '%s' "$default"
    return 0
  fi
  printf '%s [%s]: ' "$label" "$default" >&2
  read -r reply
  printf -v "$name" '%s' "${reply:-$default}"
}

local_source_dir() {
  local src="${BASH_SOURCE[0]:-}" root
  if [[ -n "${POCKETWEB_SRC:-}" ]]; then
    root="$(cd "$POCKETWEB_SRC" && pwd)" || return 1
  else
    [[ -n "$src" && -f "$src" ]] || return 1
    root="$(cd "$(dirname "$src")/.." && pwd)"
  fi
  [[ -f "$root/package.json" ]] || return 1
  grep -q '"name": "pocketweb-for-pockethernet"' "$root/package.json" || return 1
  printf '%s\n' "$root"
}

github_repo_slug() {
  local repo="${1%.git}"
  repo="${repo#https://github.com/}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s\n' "$repo"
}

valid_github_token() {
  [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

pocketweb_token() {
  printf '%s\n' "${POCKETWEB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
}

ensure_git_source_access() {
  local slug token code header_file=""
  local -a curl_args=()
  slug="$(github_repo_slug "$POCKETWEB_REPO")" || die "POCKETWEB_REPO must be an https://github.com/owner/name URL"
  token="$(pocketweb_token)"
  if [[ -n "$token" ]]; then
    valid_github_token "$token" || die "POCKETWEB_TOKEN must contain only letters, numbers, and underscores"
    header_file="$(mktemp)"
    chmod 600 "$header_file"
    printf 'Authorization: Bearer %s\n' "$token" >"$header_file"
    curl_args+=(-H "@${header_file}")
  fi
  if ! command -v curl >/dev/null 2>&1; then
    [[ -z "$header_file" ]] || rm -f "$header_file"
    die "curl is required to clone from GitHub. Install curl, or run bash proxmox/pocketweb.sh from a checkout of this private repo."
  fi
  code="$(
    curl -sS --max-time 20 "${curl_args[@]}" -o /dev/null -w '%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${slug}" || true
  )"
  [[ -z "$header_file" ]] || rm -f "$header_file"
  [[ "$code" == "200" ]] || die "GitHub did not allow a download of ${slug} (HTTP ${code:-n/a}). This repository is private, so an anonymous download cannot clone it. Clone the repo onto this Proxmox host with your SSH key or GitHub login, then run: bash proxmox/pocketweb.sh"
}

apply_local_ref() {
  local root ref
  root="$(local_source_dir)" || die "A local install needs the Pocketweb checkout that contains this script"
  if [[ ! -d "$root/.git" ]]; then
    POCKETWEB_REF="local"
    return 0
  fi
  ref="$(git -C "$root" rev-parse --short HEAD)"
  if [[ -n "$(git -C "$root" status --porcelain --ignore-submodules)" ]]; then
    ref="${ref}-dirty"
  fi
  POCKETWEB_REF="$ref"
}

write_guest_installer() {
  local dest="$1"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    # shellcheck disable=SC2016 # The trap is literal text for the guest script.
    printf '%s\n' 'trap '"'"'rm -f /root/pocketweb-token; printf "error: container install failed near line %s\n" "$LINENO" >&2'"'"' ERR'
    declare -f die info warn node_is_usable install_node render_nginx_site install_pocketweb
    printf '%s\n' 'install_pocketweb'
  } >"$dest"
  chmod 755 "$dest"
}

container_env_value() {
  local id="$1" key="$2" file value
  file="$(pct exec "$id" -- cat /opt/pocketweb/source.env 2>/dev/null || true)"
  value="$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' <<<"$file")"
  printf '%s\n' "$value"
}

wait_for_guest() {
  local id="$1" attempt
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if pct exec "$id" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "Container ${id} did not accept commands. Check: pct status ${id}"
}

confirm() {
  local reply
  [[ "${POCKETWEB_YES:-}" == "1" || ! -t 0 ]] && return 0
  printf '%s [Y/n] ' "$1" >&2
  read -r reply
  [[ -z "$reply" || "$reply" =~ ^[Yy](es)?$ ]]
}

validate_settings() {
  valid_ctid "$CTID" || die "CTID must be a number from 100 to 999999999"
  valid_hostname "$POCKETWEB_HOSTNAME" || die "Hostname must be a DNS label"
  [[ "$POCKETWEB_CORES" =~ ^[0-9]+$ && "$POCKETWEB_CORES" -ge 1 ]] || die "POCKETWEB_CORES must be at least 1"
  [[ "$POCKETWEB_MEMORY" =~ ^[0-9]+$ && "$POCKETWEB_MEMORY" -ge 2048 ]] || die "POCKETWEB_MEMORY must be at least 2048 MB"
  [[ "$POCKETWEB_DISK" =~ ^[0-9]+$ && "$POCKETWEB_DISK" -ge 8 ]] || die "POCKETWEB_DISK must be at least 8 GB"
  [[ "$POCKETWEB_BRIDGE" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Bridge name contains unsupported characters"
  [[ -d "/sys/class/net/${POCKETWEB_BRIDGE}" ]] || die "Bridge ${POCKETWEB_BRIDGE} was not found"
  [[ "$POCKETWEB_HTTPS" == "0" || "$POCKETWEB_HTTPS" == "1" ]] || die "POCKETWEB_HTTPS must be 0 or 1"
  [[ "$POCKETWEB_SOURCE" == "git" || "$POCKETWEB_SOURCE" == "local" ]] || die "POCKETWEB_SOURCE must be git or local"
  [[ "$POCKETWEB_IP" == "dhcp" || "$POCKETWEB_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] \
    || die "POCKETWEB_IP must be dhcp or an IPv4 CIDR, for example 192.168.1.50/24"
  if [[ "$POCKETWEB_IP" != "dhcp" ]]; then
    [[ "$POCKETWEB_GW" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Set POCKETWEB_GW to the gateway address"
  fi
  if [[ -n "${POCKETWEB_VLAN:-}" ]]; then
    [[ "$POCKETWEB_VLAN" =~ ^[0-9]+$ && "$POCKETWEB_VLAN" -ge 1 && "$POCKETWEB_VLAN" -le 4094 ]] \
      || die "POCKETWEB_VLAN must be from 1 to 4094"
  fi
  if [[ -n "${POCKETWEB_IP6:-}" ]]; then
    [[ "$POCKETWEB_IP6" == "auto" || "$POCKETWEB_IP6" == "dhcp" || "$POCKETWEB_IP6" =~ ^[0-9A-Fa-f:]+/[0-9]+$ ]] \
      || die "POCKETWEB_IP6 must be auto, dhcp, or an IPv6 CIDR"
  fi
  [[ "$POCKETWEB_REPO" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]] \
    || die "POCKETWEB_REPO must be an https://github.com/owner/name URL"
  [[ "$POCKETWEB_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "POCKETWEB_REF must be a branch, tag, or commit"
  [[ "$POCKETWEB_STORAGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Storage name contains unsupported characters"
  [[ "$POCKETWEB_TEMPLATE_STORAGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Template storage name contains unsupported characters"
  valid_template_name "$POCKETWEB_TEMPLATE" \
    || die "POCKETWEB_TEMPLATE must be a Debian 12 or 13 standard template"
}

valid_template_name() {
  [[ "$1" =~ ^debian-1[23]-standard_[A-Za-z0-9._-]+\.tar\.zst$ ]]
}

latest_debian_template() {
  local arch="$1"
  grep -E "^debian-1[23]-standard_.+_${arch}\\.tar\\.zst$" | sort -V | tail -n 1
}

choose_template() {
  local arch="$1" template
  if [[ -n "${POCKETWEB_TEMPLATE:-}" ]]; then
    printf '%s\n' "$POCKETWEB_TEMPLATE"
    return 0
  fi
  info "Refreshing the container template list"
  # pveam update prints "update successful" on stdout. Keep it off the value
  # captured for the template prompt.
  pveam update >&2
  template="$(pveam available --section system 2>/dev/null | awk 'NF { print $NF }' | latest_debian_template "$arch")"
  [[ -n "$template" ]] || die "No Debian 12 or 13 standard template is available for ${arch}"
  printf '%s\n' "$template"
}

ensure_template() {
  local storage="$1" template="$2"
  if pveam list "$storage" | awk '{ print $1 }' | grep -Fxq "${storage}:vztmpl/${template}"; then
    return 0
  fi
  info "Downloading ${template}"
  pveam download "$storage" "$template"
}

push_and_install() {
  local id="$1" guest archive=""
  guest="$(mktemp)"
  write_guest_installer "$guest"
  if [[ "$POCKETWEB_SOURCE" == "local" ]]; then
    local root
    root="$(local_source_dir)" || die "A local install needs the Pocketweb checkout that contains this script"
    archive="$(mktemp --suffix=.tgz)"
    info "Packing the local checkout"
    tar -C "$root" -czf "$archive" \
      --exclude node_modules \
      --exclude dist \
      --exclude .git \
      --exclude storybook-static \
      --exclude .wrangler \
      .
  fi
  wait_for_guest "$id"
  pct push "$id" "$guest" /root/pocketweb-install.sh --perms 755
  if [[ -n "$archive" ]]; then
    pct push "$id" "$archive" /tmp/pocketweb-src.tgz
  fi
  rm -f "$guest"
  [[ -z "$archive" ]] || rm -f "$archive"
  if [[ "$POCKETWEB_SOURCE" == "git" ]]; then
    local token token_file
    token="$(pocketweb_token)"
    if [[ -n "$token" ]]; then
      token_file="$(mktemp)"
      chmod 600 "$token_file"
      printf '%s' "$token" >"$token_file"
      pct push "$id" "$token_file" /root/pocketweb-token --perms 600
      rm -f "$token_file"
    fi
  fi
  info "Installing Pocketweb inside container ${id}"
  pct exec "$id" -- env \
    POCKETWEB_REPO="$POCKETWEB_REPO" \
    POCKETWEB_REF="$POCKETWEB_REF" \
    POCKETWEB_SOURCE="$POCKETWEB_SOURCE" \
    POCKETWEB_HTTPS="$POCKETWEB_HTTPS" \
    POCKETWEB_HOSTNAME="$POCKETWEB_HOSTNAME" \
    POCKETWEB_ARCHIVE="${archive:+/tmp/pocketweb-src.tgz}" \
    bash /root/pocketweb-install.sh
  pct exec "$id" -- rm -f /root/pocketweb-install.sh /root/pocketweb-token
}

print_result() {
  local id="$1" url
  url="$(pct exec "$id" -- cat /opt/pocketweb/url)"
  cat <<EOF

Pocketweb container ${id} is ready: ${url}

Open that address in Chrome or Edge on the computer that will use the
Pockethernet. Bluetooth stays on that computer. Accept the container
certificate once so the browser treats the page as a secure context.

Console: pct enter ${id}
Update:  CTID=${id} POCKETWEB_UPDATE=1 bash -c "\$(curl -fsSL ${POCKETWEB_SCRIPT_URL})"
EOF
  if [[ "$POCKETWEB_HTTPS" == "0" ]]; then
    warn "HTTPS is off. Web Bluetooth works from localhost only, not from this container address."
  fi
}

load_create_settings() {
  local template_stores root_stores arch
  prompt_value CTID "Container ID" "$(next_ctid)"
  prompt_value POCKETWEB_HOSTNAME "Hostname" "pocketweb"
  prompt_value POCKETWEB_CORES "CPU cores" "2"
  prompt_value POCKETWEB_MEMORY "Memory MB" "2048"
  prompt_value POCKETWEB_DISK "Disk GB" "8"
  if [[ -z "${POCKETWEB_BRIDGE:-}" && -d /sys/class/net/vmbr0 ]]; then
    POCKETWEB_BRIDGE="vmbr0"
  elif [[ -z "${POCKETWEB_BRIDGE:-}" ]]; then
    POCKETWEB_BRIDGE="$(ip -o link show type bridge | awk -F': ' '{ print $2; exit }')"
  fi
  prompt_value POCKETWEB_BRIDGE "Network bridge" "${POCKETWEB_BRIDGE:-vmbr0}"
  template_stores="$(storage_names vztmpl)"
  root_stores="$(storage_names rootdir)"
  [[ -n "$template_stores" ]] || die "No enabled storage can hold container templates"
  [[ -n "$root_stores" ]] || die "No enabled storage can hold a container root filesystem"
  prompt_value POCKETWEB_TEMPLATE_STORAGE "Template storage" "$(pick_template_storage "$template_stores")"
  prompt_value POCKETWEB_STORAGE "Root storage" "$(pick_root_storage "$root_stores")"
  grep -Fxq "$POCKETWEB_TEMPLATE_STORAGE" <<<"$template_stores" \
    || die "Storage ${POCKETWEB_TEMPLATE_STORAGE} cannot hold container templates"
  grep -Fxq "$POCKETWEB_STORAGE" <<<"$root_stores" \
    || die "Storage ${POCKETWEB_STORAGE} cannot hold a container root filesystem"
  arch="$(dpkg --print-architecture)"
  [[ "$arch" == "amd64" || "$arch" == "arm64" ]] || die "Unsupported host architecture: ${arch}"
  if [[ -z "${POCKETWEB_TEMPLATE:-}" ]]; then
    prompt_value POCKETWEB_TEMPLATE "Debian template" "$(choose_template "$arch")"
  fi
  prompt_value POCKETWEB_IP "IPv4 address" "dhcp"
  if [[ "${POCKETWEB_IP:-dhcp}" != "dhcp" ]]; then
    prompt_value POCKETWEB_GW "Gateway" ""
  fi
  prompt_value POCKETWEB_HTTPS "HTTPS (1 or 0)" "1"
  if [[ -z "${POCKETWEB_SOURCE:-}" ]]; then
    if [[ -n "${POCKETWEB_SRC:-}" ]] || local_source_dir >/dev/null 2>&1; then
      POCKETWEB_SOURCE="local"
    else
      POCKETWEB_SOURCE="git"
    fi
  fi
  prompt_value POCKETWEB_SOURCE "Source (git or local)" "$POCKETWEB_SOURCE"
  prompt_value POCKETWEB_REPO "Git repository" "$POCKETWEB_REPO_DEFAULT"
  POCKETWEB_MEMORY="$(normalize_mb "$POCKETWEB_MEMORY")" || die "POCKETWEB_MEMORY must be a number of megabytes"
  POCKETWEB_DISK="$(normalize_disk_gb "$POCKETWEB_DISK")" || die "POCKETWEB_DISK must be a number of gigabytes"
  if [[ "$POCKETWEB_SOURCE" == "git" ]]; then
    prompt_value POCKETWEB_REF "Git ref" "main"
  else
    apply_local_ref
  fi
}

create_container() {
  local net0="name=eth0,bridge=${POCKETWEB_BRIDGE},firewall=0,type=veth,ip=${POCKETWEB_IP}"
  if [[ "$POCKETWEB_IP" != "dhcp" ]]; then
    net0+=",gw=${POCKETWEB_GW}"
  fi
  if [[ -n "${POCKETWEB_VLAN:-}" ]]; then
    net0+=",tag=${POCKETWEB_VLAN}"
  fi
  if [[ -n "${POCKETWEB_IP6:-}" ]]; then
    net0+=",ip6=${POCKETWEB_IP6}"
  fi
  [[ ! -f "/etc/pve/lxc/${CTID}.conf" ]] || die "Container ${CTID} already exists"
  [[ ! -f "/etc/pve/qemu-server/${CTID}.conf" ]] || die "VM ID ${CTID} is already in use"
  ensure_template "$POCKETWEB_TEMPLATE_STORAGE" "$POCKETWEB_TEMPLATE"
  info "Creating container ${CTID}"
  pct create "$CTID" "${POCKETWEB_TEMPLATE_STORAGE}:vztmpl/${POCKETWEB_TEMPLATE}" \
    --arch "$(dpkg --print-architecture)" \
    --hostname "$POCKETWEB_HOSTNAME" \
    --cores "$POCKETWEB_CORES" \
    --memory "$POCKETWEB_MEMORY" \
    --swap 512 \
    --rootfs "${POCKETWEB_STORAGE}:${POCKETWEB_DISK}" \
    --net0 "$net0" \
    --unprivileged 1 \
    --onboot 1 \
    --ostype debian \
    --timezone host \
    --tags pocketweb \
    --description "Pocketweb for Pockethernet" \
    --start 0
  info "Starting container ${CTID}"
  pct start "$CTID"
}

load_update_settings() {
  prompt_value CTID "Container ID to update" ""
  [[ -n "${CTID:-}" ]] || die "Set CTID to the Pocketweb container ID"
  valid_ctid "$CTID" || die "CTID must be a number from 100 to 999999999"
  [[ -f "/etc/pve/lxc/${CTID}.conf" ]] || die "Container ${CTID} does not exist"
  pct status "$CTID" >/dev/null
  if [[ "$(pct status "$CTID" | awk '{ print $2 }')" != "running" ]]; then
    info "Starting container ${CTID}"
    pct start "$CTID"
  fi
  wait_for_guest "$CTID"
  if [[ -z "${POCKETWEB_SOURCE:-}" ]]; then
    POCKETWEB_SOURCE="$(container_env_value "$CTID" source)"
    POCKETWEB_SOURCE="${POCKETWEB_SOURCE:-git}"
  fi
  if [[ -z "${POCKETWEB_HTTPS:-}" ]]; then
    POCKETWEB_HTTPS="$(container_env_value "$CTID" https)"
    POCKETWEB_HTTPS="${POCKETWEB_HTTPS:-1}"
  fi
  if [[ -z "${POCKETWEB_HOSTNAME:-}" ]]; then
    POCKETWEB_HOSTNAME="$(container_env_value "$CTID" hostname)"
    POCKETWEB_HOSTNAME="${POCKETWEB_HOSTNAME:-pocketweb}"
  fi
  if [[ -z "${POCKETWEB_REPO:-}" ]]; then
    POCKETWEB_REPO="$(container_env_value "$CTID" repo)"
    POCKETWEB_REPO="${POCKETWEB_REPO:-$POCKETWEB_REPO_DEFAULT}"
  fi
  if [[ "$POCKETWEB_SOURCE" == "git" && -z "${POCKETWEB_REF:-}" ]]; then
    POCKETWEB_REF="$(container_env_value "$CTID" ref)"
    POCKETWEB_REF="${POCKETWEB_REF:-main}"
  fi
  if [[ "$POCKETWEB_SOURCE" == "local" ]]; then
    apply_local_ref
  else
    POCKETWEB_REF="${POCKETWEB_REF:-main}"
  fi
  [[ "$POCKETWEB_HTTPS" == "0" || "$POCKETWEB_HTTPS" == "1" ]] || die "POCKETWEB_HTTPS must be 0 or 1"
  [[ "$POCKETWEB_SOURCE" == "git" || "$POCKETWEB_SOURCE" == "local" ]] || die "POCKETWEB_SOURCE must be git or local"
  [[ "$POCKETWEB_REPO" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]] \
    || die "POCKETWEB_REPO must be an https://github.com/owner/name URL"
  [[ "$POCKETWEB_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "POCKETWEB_REF must be a branch, tag, or commit"
  valid_hostname "$POCKETWEB_HOSTNAME" || die "Hostname must be a DNS label"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_usage
    return 0
  fi
  if [[ $# -gt 0 ]]; then
    print_usage >&2
    return 1
  fi
  if [[ ! -d /etc/pve ]]; then
    die "Run this on a Proxmox VE host shell. It creates an LXC container with pct."
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Run this script as root on the Proxmox VE host."
  fi
  command -v pct >/dev/null 2>&1 || die "pct was not found. Install the Proxmox VE container tools on this host."
  command -v pvesm >/dev/null 2>&1 || die "pvesm was not found. Install the Proxmox VE storage tools on this host."
  command -v pveam >/dev/null 2>&1 || die "pveam was not found. Install the Proxmox VE container tools on this host."

  if [[ "${POCKETWEB_UPDATE:-}" == "1" ]]; then
    load_update_settings
    if [[ "$POCKETWEB_SOURCE" == "git" ]]; then
      ensure_git_source_access
    fi
    cat <<EOF
Update Pocketweb container ${CTID}
  Source: ${POCKETWEB_SOURCE} ${POCKETWEB_REF}
  HTTPS:  ${POCKETWEB_HTTPS}
EOF
    confirm "Update this container?" || die "Cancelled"
    push_and_install "$CTID"
    print_result "$CTID"
    return 0
  fi

  load_create_settings
  validate_settings
  if [[ "$POCKETWEB_SOURCE" == "git" ]]; then
    ensure_git_source_access
  fi
  cat <<EOF
Create Pocketweb container ${CTID}
  Hostname: ${POCKETWEB_HOSTNAME}
  Resources: ${POCKETWEB_CORES} CPU, ${POCKETWEB_MEMORY} MB RAM, ${POCKETWEB_DISK} GB disk
  Storage: ${POCKETWEB_STORAGE}
  Template: ${POCKETWEB_TEMPLATE_STORAGE}:vztmpl/${POCKETWEB_TEMPLATE}
  Network: ${POCKETWEB_IP} on ${POCKETWEB_BRIDGE}
  HTTPS: ${POCKETWEB_HTTPS}
  Source: ${POCKETWEB_SOURCE} ${POCKETWEB_REF}
EOF
  confirm "Create this container?" || die "Cancelled"
  create_container
  push_and_install "$CTID"
  print_result "$CTID"
}

_pocketweb_source="${BASH_SOURCE[0]:-}"
if [[ -z "$_pocketweb_source" || "$_pocketweb_source" == "$0" ]]; then
  main "$@"
fi
