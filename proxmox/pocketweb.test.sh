#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # Sourced path is resolved at runtime.
source "${root}/pocketweb.sh"

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'assertion failed: %s\nexpected: %s\nactual:   %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'assertion failed: %s\nmissing: %s\n' "$label" "$needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'assertion failed: %s\nunexpected: %s\n' "$label" "$needle" >&2
    exit 1
  fi
}

https="$(render_nginx_site /assets/index-new123.js /assets/index-new123.css 1)"
assert_contains "$https" "listen 443 ssl default_server;" "https listen"
assert_contains "$https" "return 301 https://\$host\$request_uri;" "https redirect"
assert_contains "$https" "proxy_pass https://ota.pockethernet.com/latest_version;" "version proxy"
assert_contains "$https" "proxy_pass http://127.0.0.1:8787;" "brand proxy"
assert_contains "$https" "limit_except GET POST PUT { deny all; }" "brand methods"
assert_contains "$https" "location = /assets/index-new123.js" "current script"
assert_contains "$https" "try_files /assets/index-new123.js =404;" "legacy script"
assert_contains "$https" "try_files /assets/index-new123.css =404;" "legacy style"
assert_contains "$https" "try_files /assets/logo.png =404;" "legacy logo"
assert_contains "$https" "try_files /pockethernet-192.png /logo-192.png =404;" "legacy icon"
assert_contains "$https" "try_files \$uri \$uri/ /index.html;" "spa fallback"
assert_contains "$https" 'limit_except GET { deny all; }' "version method"

http="$(render_nginx_site /assets/index-new123.js /assets/index-new123.css 0)"
assert_not_contains "$http" "ssl_certificate" "http has no certificate"
assert_contains "$http" "listen 80 default_server;" "http listen"
assert_not_contains "$http" "listen 443" "http has no tls listener"

assert_eq "$(pick_template_storage $'local\nother')" "local" "template storage prefers local"
assert_eq "$(pick_template_storage $'nas')" "nas" "template storage uses the only store"
assert_eq "$(pick_root_storage $'local\nlocal-lvm')" "local-lvm" "root storage prefers lvm"
assert_eq "$(pick_root_storage $'local\nfast-zfs')" "fast-zfs" "root storage avoids directory local"
assert_eq "$(pick_root_storage $'local')" "local" "root storage falls back to local"
assert_eq "$(normalize_mb 2048MB)" "2048" "memory suffix"
assert_eq "$(normalize_disk_gb 8G)" "8" "disk suffix"
valid_template_name "debian-13-standard_13.6-1_amd64.tar.zst"
if valid_template_name $'update successful\ndebian-13-standard_13.6-1_amd64.tar.zst'; then
  echo "template status text should be rejected" >&2
  exit 1
fi
assert_eq "$(printf '%s\n' 'update successful' 'debian-12-standard_12.12-1_amd64.tar.zst' 'debian-13-standard_13.6-1_amd64.tar.zst' | latest_debian_template amd64)" \
  "debian-13-standard_13.6-1_amd64.tar.zst" "template list ignores pveam status"
valid_ctid 100
if valid_ctid 99; then
  echo "CTID 99 should be rejected" >&2
  exit 1
fi
valid_hostname pocketweb
if valid_hostname "bad host"; then
  echo "hostname with a space should be rejected" >&2
  exit 1
fi

guest="$(mktemp)"
write_guest_installer "$guest"
bash -n "$guest"
rm -f "$guest"

bash -n "$root/pocketweb.sh"
help="$(bash "$root/pocketweb.sh" --help)"
assert_contains "$help" "POCKETWEB_UPDATE" "help lists update"
assert_contains "$help" "Updates follow main unless this is set." "help updates from main"
brand_unit="$(declare -f install_brand_service)"
assert_contains "$brand_unit" "ExecStart=\${node_bin} /opt/pocketweb/brand-server.mjs" "brand service runs javascript"
assert_not_contains "$brand_unit" "experimental-strip-types" "brand service does not run typescript"
assert_contains "$(declare -f bundle_brand_server)" "outfile: '/opt/pocketweb/brand-server.mjs'" "brand bundle target"
assert_contains "$(declare -f install_pocketweb)" "journalctl -u pocketweb-brand" "brand failure shows the journal"
guest_body="$(declare -f bundle_brand_server)"
assert_contains "$guest_body" "import * as esbuild from 'esbuild';" "guest installer bundles the brand server"
one_line="$(bash -c "$(cat "$root/pocketweb.sh")" 2>&1 || true)"
assert_contains "$one_line" "Run this on a Proxmox VE host shell" "one-liner entrypoint refuses a workstation"

if (render_nginx_site ' /not-a-script' /assets/index-new123.css 1 >/dev/null 2>&1); then
  echo "unsafe script path should be rejected" >&2
  exit 1
fi

assert_eq "$(github_repo_slug "https://github.com/Emile098/Pockethernet-Web.git")" \
  "Emile098/Pockethernet-Web" "github slug"
valid_github_token "github_pat_abc123"
if valid_github_token "bad token"; then
  echo "token with a space should be rejected" >&2
  exit 1
fi
checkout="$(local_source_dir)"
[[ -f "$checkout/package.json" ]]
POCKETWEB_SRC="$checkout"
assert_eq "$(local_source_dir)" "$checkout" "explicit checkout"
# shellcheck disable=SC2034 # Read by local_source_dir.
POCKETWEB_SRC="/tmp"
if local_source_dir >/dev/null; then
  echo "unrelated directory should not be a Pocketweb checkout" >&2
  exit 1
fi
unset POCKETWEB_SRC

if command -v nginx >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  work="$(mktemp -d)"
  openssl req -x509 -nodes -newkey rsa:2048 -keyout "$work/pocketweb.key" -out "$work/pocketweb.crt" \
    -days 1 -subj "/CN=pocketweb" >/dev/null 2>&1
  rewrite_listen() {
    sed \
      -e "s#/etc/nginx/ssl#${work}#g" \
      -e 's/listen 80 default_server;/listen 127.0.0.1:8080 default_server;/' \
      -e 's/listen \[::\]:80 default_server;/listen [::]:8080 default_server;/' \
      -e 's/listen 443 ssl default_server;/listen 127.0.0.1:8443 ssl default_server;/' \
      -e 's/listen \[::\]:443 ssl default_server;/listen [::]:8443 ssl default_server;/'
  }
  render_nginx_site /assets/index-new123.js /assets/index-new123.css 1 | rewrite_listen >"$work/https.conf"
  render_nginx_site /assets/index-new123.js /assets/index-new123.css 0 | rewrite_listen >"$work/http.conf"
  for site in https.conf http.conf; do
    mkdir -p "$work/body" "$work/proxy" "$work/fastcgi" "$work/uwsgi" "$work/scgi"
    cat >"$work/nginx.conf" <<EOF
worker_processes 1;
error_log ${work}/error.log;
pid ${work}/nginx.pid;
events { worker_connections 64; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log ${work}/access.log;
    client_body_temp_path ${work}/body;
    proxy_temp_path ${work}/proxy;
    fastcgi_temp_path ${work}/fastcgi;
    uwsgi_temp_path ${work}/uwsgi;
    scgi_temp_path ${work}/scgi;
    include ${work}/${site};
}
EOF
    nginx -t -c "$work/nginx.conf"
  done
  rm -rf "$work"
fi

printf 'nginx config and installer checks passed\n'
