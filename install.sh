#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY="https://github.com/scssw/Marzban.git"
SOURCE_DIR="/opt/scssw-marzban"
INSTALL_DIR="/opt/marzban"
DATA_DIR="/var/lib/marzban"

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi
cd /

if [[ ! -f /etc/debian_version ]] || ! command -v apt-get >/dev/null 2>&1; then
    echo "此安装脚本目前支持 Debian/Ubuntu。" >&2
    exit 1
fi

read -r -p "绑定域名: " DOMAIN
if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$DOMAIN" != *.* ]]; then
    echo "请输入有效域名。" >&2
    exit 1
fi
read -r -p "面板管理员用户名: " ADMIN_USERNAME
if [[ ! "$ADMIN_USERNAME" =~ ^[A-Za-z0-9_.@-]{3,32}$ ]]; then
    echo "用户名须为 3 至 32 位字母、数字或 . _ @ -。" >&2
    exit 1
fi
while true; do
    read -r -s -p "面板管理员密码（至少 8 位）: " ADMIN_PASSWORD
    echo
    read -r -s -p "再次输入密码: " ADMIN_PASSWORD_CONFIRM
    echo
    if [[ ${#ADMIN_PASSWORD} -ge 8 && "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
        break
    fi
    echo "密码不匹配或少于 8 位，请重试。" >&2
done
unset ADMIN_PASSWORD_CONFIRM

apt-get update
apt-get install -y ca-certificates curl git python3 python3-venv python3-pip certbot iproute2
if ss -H -ltn 'sport = :8188' | grep -q .; then
    echo "TCP 8188 已被占用，请释放该端口后重新安装。" >&2
    exit 1
fi

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

if [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    docker compose -f "$INSTALL_DIR/docker-compose.yml" down || true
fi
if ss -H -ltn 'sport = :8188' | grep -q .; then
    echo "TCP 8188 仍被其他程序占用，请释放该端口后重试。" >&2
    exit 1
fi

if [[ -d "$SOURCE_DIR/.git" ]]; then
    git -C "$SOURCE_DIR" fetch --depth 1 origin master
    git -C "$SOURCE_DIR" reset --hard FETCH_HEAD
elif [[ -e "$SOURCE_DIR" ]]; then
    echo "$SOURCE_DIR 存在但不是 Git 仓库；请先检查后移走该源码目录。" >&2
    exit 1
else
    git clone --depth 1 "$REPOSITORY" "$SOURCE_DIR"
fi
mkdir -p "$INSTALL_DIR" "$DATA_DIR"
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
    cp "$SOURCE_DIR/.env.example" "$INSTALL_DIR/.env"
fi
chmod 600 "$INSTALL_DIR/.env"
if [[ ! -f "$DATA_DIR/xray_config.json" ]]; then
    cp "$SOURCE_DIR/xray_config.json" "$DATA_DIR/xray_config.json"
fi

if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" || ! -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]] \
    || ! openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -checkend 86400 -noout >/dev/null 2>&1; then
    certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$DOMAIN"
fi

set_env() {
    local key="$1" value="$2"
    if grep -qE "^#?${key}[[:space:]]*=" "$INSTALL_DIR/.env"; then
        sed -i -E "s|^#?${key}[[:space:]]*=.*|${key} = \"${value}\"|" "$INSTALL_DIR/.env"
    else
        printf '%s = "%s"\n' "$key" "$value" >> "$INSTALL_DIR/.env"
    fi
}
set_env XRAY_JSON /var/lib/marzban/xray_config.json
set_env SQLALCHEMY_DATABASE_URL sqlite:////var/lib/marzban/db.sqlite3
set_env UVICORN_PORT 8188
set_env UVICORN_SSL_CERTFILE "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
set_env UVICORN_SSL_KEYFILE "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
set_env XRAY_SUBSCRIPTION_URL_PREFIX "https://$DOMAIN"

python3 -m venv "$INSTALL_DIR/venv"
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

ADMIN_CREATED=false
for attempt in $(seq 1 60); do
    if OUTPUT=$(printf '%s\n%s\n' "$ADMIN_USERNAME" "$ADMIN_PASSWORD" | docker compose -f "$INSTALL_DIR/docker-compose.yml" exec -T marzban sh -c 'read -r username; read -r password; export MARZBAN_ADMIN_PASSWORD="$password"; exec marzban-cli admin create --username "$username" --sudo --telegram-id 0 --discord-webhook ""' 2>&1); then
        echo "$OUTPUT"
        ADMIN_CREATED=true
        break
    elif [[ "$OUTPUT" == *"already exists"* ]]; then
        echo "管理员 $ADMIN_USERNAME 已存在，保留现有账号和密码。"
        ADMIN_CREATED=true
        break
    fi
    sleep 2
done
unset ADMIN_PASSWORD
if [[ "$ADMIN_CREATED" != true ]]; then
    echo "管理员创建失败；查看日志：docker compose -f $INSTALL_DIR/docker-compose.yml logs marzban" >&2
    exit 1
fi

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
echo "安装完成。面板地址: https://$DOMAIN:8188/dashboard/"
echo "管理员用户名: $ADMIN_USERNAME"
echo "运行 tls 进入服务器管理菜单。"
