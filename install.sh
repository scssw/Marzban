#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="https://github.com/scssw/Marzban.git"
SOURCE_DIR="/opt/scssw-marzban"
INSTALL_DIR="/opt/marzban"
DATA_DIR="/var/lib/marzban"

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

if [[ ! -f /etc/debian_version ]] || ! command -v apt-get >/dev/null 2>&1; then
    echo "此安装脚本目前支持 Debian/Ubuntu。" >&2
    exit 1
fi

if [[ -e "$INSTALL_DIR" ]]; then
    echo "$INSTALL_DIR 已存在。为保护现有配置和数据，安装程序不会覆盖它。" >&2
    echo "请先备份数据，并将现有安装目录移走后重试。" >&2
    exit 1
fi

apt-get update
apt-get install -y ca-certificates curl git python3 python3-venv python3-pip certbot

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin || {
        echo "Docker Compose 插件安装失败，请确认系统源提供 docker-compose-plugin。" >&2
        exit 1
    }
fi
systemctl enable --now docker

if [[ -e "$SOURCE_DIR" ]]; then
    echo "$SOURCE_DIR 已存在；请先检查并移走旧源码目录。" >&2
    exit 1
fi
git clone --depth 1 "$REPOSITORY" "$SOURCE_DIR"
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
cp "$SOURCE_DIR/.env.example" "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"
cp "$SOURCE_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
if [[ ! -f "$DATA_DIR/xray_config.json" ]]; then
    cp "$SOURCE_DIR/xray_config.json" "$DATA_DIR/xray_config.json"
fi

sed -i 's|^# *XRAY_JSON *=.*|XRAY_JSON = "/var/lib/marzban/xray_config.json"|' "$INSTALL_DIR/.env"
sed -i 's|^# *SQLALCHEMY_DATABASE_URL *=.*|SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"|' "$INSTALL_DIR/.env"

read -r -p "现在绑定域名并申请 HTTPS 证书？(y/N): " BIND_DOMAIN
if [[ "$BIND_DOMAIN" =~ ^[Yy]$ ]]; then
    read -r -p "域名: " DOMAIN
    read -r -p "证书通知邮箱: " CERT_EMAIL
    if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || [[ -z "$CERT_EMAIL" ]]; then
        echo "域名或邮箱格式无效。" >&2
        exit 1
    fi
    certbot certonly --standalone --non-interactive --agree-tos --email "$CERT_EMAIL" -d "$DOMAIN"
    printf '\nUVICORN_SSL_CERTFILE="/etc/letsencrypt/live/%s/fullchain.pem"\nUVICORN_SSL_KEYFILE="/etc/letsencrypt/live/%s/privkey.pem"\nXRAY_SUBSCRIPTION_URL_PREFIX="https://%s"\n' \
        "$DOMAIN" "$DOMAIN" "$DOMAIN" >> "$INSTALL_DIR/.env"
fi

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -r "$SOURCE_DIR/requirements.txt"

cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  marzban:
    image: scssw/marzban:local
    build:
      context: $SOURCE_DIR
    container_name: marzban
    restart: always
    env_file: .env
    network_mode: host
    volumes:
      - $DATA_DIR:/var/lib/marzban
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF

docker compose -f "$INSTALL_DIR/docker-compose.yml" build
docker compose -f "$INSTALL_DIR/docker-compose.yml" up -d

if [[ -d /etc/letsencrypt/renewal-hooks/deploy ]]; then
    cat > /etc/letsencrypt/renewal-hooks/deploy/restart-scssw-marzban <<EOF
#!/bin/sh
docker compose -f "$INSTALL_DIR/docker-compose.yml" restart marzban
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/restart-scssw-marzban
fi

cat > /usr/local/bin/tls <<EOF
#!/usr/bin/env bash
if [[ \$EUID -ne 0 ]]; then
    exec sudo /usr/local/bin/tls "\$@"
fi
cd "$INSTALL_DIR"
export PYTHONPATH="$SOURCE_DIR"
export MARZBAN_ENV_FILE="$INSTALL_DIR/.env"
export MARZBAN_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
exec "$INSTALL_DIR/venv/bin/python" "$SOURCE_DIR/marzban-cli.py" tls "\$@"
EOF
chmod 755 /usr/local/bin/tls

echo
if [[ -n "${DOMAIN:-}" ]]; then
    echo "安装完成。面板地址: https://$DOMAIN:8000/dashboard/"
else
    echo "安装完成。未绑定域名时面板仅监听本机，可运行 tls 绑定域名或使用 SSH 转发。"
fi
echo "运行 tls 进入管理菜单；首次请先创建管理员："
echo "  cd $INSTALL_DIR && PYTHONPATH=$SOURCE_DIR $INSTALL_DIR/venv/bin/python $SOURCE_DIR/marzban-cli.py admin create --sudo"
