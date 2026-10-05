#!/bin/bash

SERVICE_NAME="marzban"
SERVICE_DESCRIPTION="Marzban Service"
SERVICE_DOCUMENTATION="https://github.com/gozargah/marzban"
MAIN_PY_PATH="$PWD/main.py"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
ENV_FILE="$PWD/.env"

read -r -p "绑定域名并申请 Let's Encrypt 证书？(y/N): " BIND_DOMAIN
if [[ "$BIND_DOMAIN" =~ ^[Yy]$ ]]; then
    read -r -p "域名: " DOMAIN
    read -r -p "证书通知邮箱: " CERT_EMAIL
    if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || [[ -z "$CERT_EMAIL" ]]; then
        echo "域名或邮箱格式无效" >&2
        exit 1
    fi
    if ! command -v certbot >/dev/null 2>&1; then
        echo "请先安装 certbot，并确保 80 端口可从公网访问。" >&2
        exit 1
    fi
    certbot certonly --standalone --non-interactive --agree-tos --email "$CERT_EMAIL" -d "$DOMAIN" || exit 1
    touch "$ENV_FILE"
    sed -i '/^UVICORN_SSL_CERTFILE=/d; /^UVICORN_SSL_KEYFILE=/d' "$ENV_FILE"
    printf 'UVICORN_SSL_CERTFILE="/etc/letsencrypt/live/%s/fullchain.pem"\nUVICORN_SSL_KEYFILE="/etc/letsencrypt/live/%s/privkey.pem"\n' "$DOMAIN" "$DOMAIN" >> "$ENV_FILE"
fi

# Create the service file
cat > $SERVICE_FILE <<EOF
[Unit]
Description=$SERVICE_DESCRIPTION
Documentation=$SERVICE_DOCUMENTATION
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/bin/env python3 $MAIN_PY_PATH
Restart=on-failure
WorkingDirectory=$PWD

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

SHORTCUT="/usr/local/bin/tls"
printf '#!/bin/sh\nexec python3 "%s/marzban-cli.py" tls "$@"\n' "$PWD" > "$SHORTCUT"
chmod 755 "$SHORTCUT"

echo "Service file created at: $SERVICE_FILE"
echo "Interactive management shortcut installed: tls"
