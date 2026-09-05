#!/usr/bin/env bash
# "web" role: a standalone edge box outside the cluster. nginx terminates HTTP/HTTPS and
# reverse-proxies to the API's NodePort on every worker, so clients never talk to a node
# directly. Also a realistic target for the security routines (TLS, headers, exposure).
# Env: WORKERS="ip1 ip2 ..." (from the Vagrantfile), NODE_PORT (api, default 30080),
#      SITE_PORT (web Deployment, default 30081)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${WORKERS:?WORKERS env (worker IPs) is required}"
NODE_PORT="${NODE_PORT:-30080}"
SITE_PORT="${SITE_PORT:-30081}"

apt-get update -q
apt-get install -y -q nginx openssl curl

# Self-signed cert for the edge (lab only; replace with a real one via certbot/ACME)
if [ ! -s /etc/nginx/edge.crt ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 -subj "/CN=$(hostname)" \
    -addext "subjectAltName=DNS:$(hostname),IP:$(hostname -I | awk '{print $2}')" \
    -keyout /etc/nginx/edge.key -out /etc/nginx/edge.crt >/dev/null 2>&1
  chmod 600 /etc/nginx/edge.key
fi

upstreams=""; site_upstreams=""
for ip in $WORKERS; do
  upstreams+="    server ${ip}:${NODE_PORT} max_fails=2 fail_timeout=10s;"$'\n'
  site_upstreams+="    server ${ip}:${SITE_PORT} max_fails=2 fail_timeout=10s;"$'\n'
done

cat >/etc/nginx/sites-available/edge <<NGINX
upstream api {
${upstreams}}
upstream site {
${site_upstreams}}

server {
    listen 80 default_server;
    listen 443 ssl default_server;
    ssl_certificate     /etc/nginx/edge.crt;
    ssl_certificate_key /etc/nginx/edge.key;
    server_name _;
    server_tokens off;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;

    location = /edge-healthz { return 200 "ok\n"; add_header Content-Type text/plain; }

    # everything else -> the web Deployment (static site + its own /api/ proxy) via NodePort
    location / {
        proxy_pass http://site;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 3s;
        proxy_next_upstream error timeout http_502 http_503;
    }

    # /api/... straight to the api NodePort (works even if the web pods are down)
    location /api/ {
        proxy_pass http://api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 3s;
        proxy_next_upstream error timeout http_502 http_503;
    }
    # Swagger UI fetches /openapi.json from the root, so pass both through unprefixed
    location ~ ^/(docs|openapi\.json)$ { proxy_pass http://api; proxy_set_header Host \$host; }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/edge /etc/nginx/sites-enabled/edge
nginx -t
systemctl enable nginx
systemctl reload nginx || systemctl restart nginx
echo "Edge ready: http://$(hostname -I | awk '{print $2}')/  (/ -> :${SITE_PORT}, /api/ -> :${NODE_PORT} on ${WORKERS// /, })"
