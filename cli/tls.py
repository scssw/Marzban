import calendar
import secrets
import shutil
import sqlite3
import subprocess
from datetime import datetime
from pathlib import Path
from uuid import uuid4

import typer
from rich.table import Table

from app import xray
from app.db import GetDB, crud
from app.db.base import IS_SQLITE, engine
from app.db.models import User as DBUser
from app.models.proxy import ProxyTypes
from app.models.user import UserCreate, UserModify
from app.xray import operations
from . import utils

app = typer.Typer(no_args_is_help=False, help="Interactive server and user management")
GIB = 1024 ** 3


def prompt_int(label, minimum=1, maximum=None):
    while True:
        try:
            value = int(typer.prompt(label))
            if value < minimum or (maximum is not None and value > maximum):
                raise ValueError
            return value
        except ValueError:
            typer.echo("请输入有效数字。")


def expiration_for_quota(quota):
    if 50 <= quota <= 600 and quota % 50 == 0:
        months = quota // 50
        now = datetime.now()
        month_index = now.month - 1 + months
        year = now.year + month_index // 12
        month = month_index % 12 + 1
        day = min(now.day, calendar.monthrange(year, month)[1])
        return int(now.replace(year=year, month=month, day=day).timestamp())
    date_text = typer.prompt("输入到期日期 (例 27.5.3)")
    try:
        year, month, day = (int(part) for part in date_text.split("."))
        year += 2000 if year < 100 else 0
        return int(datetime(year, month, day, 23, 59, 59).timestamp())
    except (ValueError, TypeError):
        raise typer.BadParameter("日期格式应为 年.月.日，例如 27.5.3")


def create_user(quota, expire, inbound_tag=None, manual_port=None):
    protocols = {key: value for key, value in xray.config.inbounds_by_protocol.items() if value}
    if not protocols:
        typer.echo("没有启用的代理入站，无法新增用户。")
        return
    protocol_name = typer.prompt("协议", type=typer.Choice([p.value for p in protocols]))
    protocol = ProxyTypes(protocol_name)
    inbounds = protocols[protocol]
    selected = inbound_tag
    if selected is None:
        if manual_port is not None:
            matches = [item for item in inbounds if str(item.get("port")) == str(manual_port)]
            if not matches:
                typer.echo(f"协议 {protocol_name} 下没有监听端口 {manual_port} 的入站。")
                return
            selected = matches[0]["tag"]
        else:
            for index, inbound in enumerate(inbounds, 1):
                typer.echo(f"{index}. {inbound['tag']} (端口 {inbound.get('port', '-')})")
            selected = inbounds[prompt_int("选择入站序号", 1, len(inbounds)) - 1]["tag"]
    username = "u" + secrets.token_hex(6)
    model = protocol.settings_model.model_validate({"id": str(uuid4())}) if protocol in (ProxyTypes.VLESS, ProxyTypes.VMess) else protocol.settings_model()
    with GetDB() as db:
        payload = UserCreate(
            username=username,
            proxies={protocol.value: model.model_dump(mode="json")},
            inbounds={protocol.value: [selected]},
            data_limit=quota * GIB,
            expire=expire,
            note=f"tls managed; inbound={selected}",
        )
        user = crud.create_user(db, payload)
        operations.add_user(user)
        typer.echo(f"已创建用户：ID {user.id} / {user.username}，入站 {selected}")
        typer.echo(f"凭据：{user.proxies[0].settings}")


def users_menu():
    while True:
        typer.echo("\n用户管理\n1. 一键新增  2. 手动新增  3. 修改节点/用户  0. 返回")
        choice = typer.prompt("选择", default="0")
        if choice == "0":
            return
        if choice in ("1", "2"):
            quota = prompt_int("流量上限 (GB)", 1, 600 if choice == "1" else None)
            if choice == "1":
                expire = expiration_for_quota(quota)
            else:
                expire = None
            create_user(quota, expire, manual_port=prompt_int("端口", 1, 65535) if choice == "2" else None)
        elif choice == "3":
            edit_user()


def edit_user():
    identity = typer.prompt("输入用户 ID 或用户名")
    with GetDB() as db:
        user = db.query(DBUser).filter(DBUser.id == int(identity)).first() if identity.isdigit() else crud.get_user(db, identity)
        if not user:
            typer.echo("找不到用户")
            return
        typer.echo(f"1. 删除  2. 修改到期时间  3. 修改流量")
        action = typer.prompt("选择")
        if action == "1":
            if typer.confirm(f"确认删除 {user.username}？", abort=True):
                operations.remove_user(user)
                crud.remove_user(db, user)
        elif action in ("2", "3"):
            fields = {"expire": user.expire} if action == "2" else {"data_limit": user.data_limit}
            value = typer.prompt("输入 Unix 时间戳 (0 永不过期)" if action == "2" else "输入流量 GB (0 不限)", default="0")
            if action == "2":
                fields["expire"] = int(value) or None
            else:
                fields["data_limit"] = int(value) * GIB or None
            updated = crud.update_user(db, user, UserModify(**fields))
            operations.update_user(updated)
            typer.echo("已更新")


def usage_menu():
    by_port = {}
    with GetDB() as db:
        for user in crud.get_users(db):
            for proxy_type, tags in user.inbounds.items():
                for tag in tags:
                    inbound = xray.config.inbounds_by_tag.get(tag, {})
                    port = inbound.get("port", "未知")
                    bucket = by_port.setdefault(port, {"users": [], "tags": set()})
                    bucket["users"].append((user, tag))
                    bucket["tags"].add(tag)
        table = Table("序号", "端口", "用户数", "总消耗")
        entries = sorted(by_port.items(), key=lambda item: str(item[0]))
        for index, (port, bucket) in enumerate(entries, 1):
            total = 0
            for tag in bucket["tags"]:
                try:
                    stats = xray.api.get_inbound_stats(tag)
                    total += stats.uplink + stats.downlink
                except Exception:
                    total = None
                    break
            total_text = readable(total) if total is not None else "统计不可用"
            table.add_row(str(index), str(port), f"{len(bucket['users'])}（多用户）" if len(bucket['users']) > 1 else "1", total_text)
        utils.rich_console.print(table)
        if entries:
            selection = typer.prompt("输入序号查看用户用量，回车返回", default="")
            if selection.isdigit() and 1 <= int(selection) <= len(entries):
                port, bucket = entries[int(selection) - 1]
                for user, tag in bucket["users"]:
                    typer.echo(f"{user.id}.{user.username} [{tag}]  全账号累计 {readable(user.used_traffic)}")


def readable(value):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.2f} {unit}"
        value /= 1024


def domain_menu():
    typer.echo("1. 申请/换绑公网域名证书  2. 指定本地域名  0. 返回")
    choice = typer.prompt("选择", default="0")
    if choice == "0":
        return
    domain = typer.prompt("域名").strip().lower()
    if not domain or any(char not in "abcdefghijklmnopqrstuvwxyz0123456789.-" for char in domain):
        raise typer.BadParameter("域名格式无效")
    root = Path.cwd()
    env_file = root / ".env"
    values = {}
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"\'')
    if choice == "1":
        if not shutil.which("certbot"):
            typer.echo("请先安装 certbot。")
            return
        email = typer.prompt("证书通知邮箱")
        subprocess.run(["certbot", "certonly", "--standalone", "--non-interactive", "--agree-tos", "--email", email, "-d", domain], check=True)
        values["UVICORN_SSL_CERTFILE"] = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
        values["UVICORN_SSL_KEYFILE"] = f"/etc/letsencrypt/live/{domain}/privkey.pem"
    elif choice == "2":
        values["UVICORN_SSL_CERTFILE"] = typer.prompt("证书文件路径")
        values["UVICORN_SSL_KEYFILE"] = typer.prompt("私钥文件路径")
        if not Path(values["UVICORN_SSL_CERTFILE"]).is_file() or not Path(values["UVICORN_SSL_KEYFILE"]).is_file():
            raise typer.BadParameter("指定证书或密钥文件不存在")
    else:
        return
    env_file.write_text("".join(f'{key}="{value}"\n' for key, value in values.items()))
    subprocess.run(["systemctl", "restart", "marzban"], check=True)
    typer.echo(f"域名配置已写入 {env_file}，服务已重启。")


def backup_menu():
    if not IS_SQLITE:
        typer.echo("当前数据库不是 SQLite；请使用对应数据库的原生备份工具。")
        return
    folder = Path("/root/anytlsback")
    folder.mkdir(parents=True, exist_ok=True)
    backups = sorted(folder.glob("*.db"), reverse=True)
    typer.echo("1. 备份数据  2. 还原数据")
    choice = typer.prompt("选择", default="1")
    if choice == "1":
        target = folder / f"marzban-{datetime.now():%Y%m%d-%H%M%S}.db"
        source = engine.raw_connection()
        destination = sqlite3.connect(target)
        try:
            source.driver_connection.backup(destination)
        finally:
            destination.close()
            source.close()
        typer.echo(f"备份完成：{target}")
    elif choice == "2":
        backups = sorted(folder.glob("*.db"))
        if not backups:
            typer.echo("备份目录没有 .db 文件")
            return
        for index, path in enumerate(backups, 1):
            typer.echo(f"{index}. {path.name}")
        selected = backups[prompt_int("选择备份", 1, len(backups)) - 1]
        if typer.confirm(f"将用 {selected.name} 覆盖当前数据库并重启服务？", abort=True):
            subprocess.run(["systemctl", "stop", "marzban"], check=True)
            shutil.copy2(selected, Path(engine.url.database))
            subprocess.run(["systemctl", "start", "marzban"], check=True)


@app.callback(invoke_without_command=True)
def menu(ctx: typer.Context):
    if ctx.invoked_subcommand:
        return
    while True:
        typer.echo("\nTLS 管理菜单\n1. 服务器控制\n2. 新增/管理用户\n3. 用户流量\n4. 绑定域名\n5. 程序管理\n0. 退出")
        choice = typer.prompt("选择", default="0")
        if choice == "0":
            return
        if choice == "1":
            action = typer.prompt("1. 暂停  2. 重启  3. 状态", default="3")
            command = {"1": "stop", "2": "restart", "3": "status"}.get(action)
            if command:
                subprocess.run(["systemctl", command, "marzban"], check=False)
        elif choice == "2":
            users_menu()
        elif choice == "3":
            usage_menu()
        elif choice == "4":
            domain_menu()
        elif choice == "5":
            backup_menu()


@app.command("install-shortcut")
def install_shortcut():
    source = Path(__file__).resolve().parents[1] / "marzban-cli.py"
    target = Path("/usr/local/bin/tls")
    target.write_text(f"#!/bin/sh\nexec python3 {source} tls \"$@\"\n")
    target.chmod(0o755)
    typer.echo(f"快捷命令已安装：{target}")
