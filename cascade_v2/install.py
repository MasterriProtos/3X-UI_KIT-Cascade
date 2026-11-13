#!/usr/bin/env python3
"""3X-UI KIT Cascade v2 - clean Ubuntu 24.04 EXIT/RELAY installer.

Only installs official Xray-core and its config. Does NOT change firewall,
routing, SSH, UFW, DNS, or the original KIT on any server.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import getpass
import http.client
import grp
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

import hops

STATE_DIR = Path("/etc/kit-cascade")
STATE_FILE = STATE_DIR / "state.json"
LINK_FILE = STATE_DIR / "link.txt"
MANAGED_CORE = STATE_DIR / "managed-core.txt"
CONFIG_FILE = Path("/usr/local/etc/xray/config.json")
XRAY = Path("/usr/local/bin/xray")
XRAY_UNIT = Path("/etc/systemd/system/xray.service")
# Fixed upstream installer revision reviewed for this project.
INSTALL_SCRIPT_COMMIT = "1bce9c3a9630d72521643159080017d1c001bc71"
INSTALL_SCRIPT_URL = (
    "https://raw.githubusercontent.com/XTLS/Xray-install/"
    + INSTALL_SCRIPT_COMMIT + "/install-release.sh"
)


class InstallError(RuntimeError):
    pass


def run(args, *, timeout=30, capture=True, check=True):
    try:
        return subprocess.run(
            [str(x) for x in args], check=check, timeout=timeout,
            text=True, capture_output=capture,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        detail = getattr(exc, "stderr", None) or getattr(exc, "stdout", None) or str(exc)
        raise InstallError(f"Команда {args[0]} завершилась с ошибкой: {str(detail)[-900:]}") from exc


def require_environment():
    if os.geteuid() != 0:
        raise InstallError("Запускайте через sudo от root")
    if not sys.stdin.isatty():
        raise InstallError("Для безопасной установки нужен интерактивный терминал")
    details = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            details[k] = v.strip().strip('"')
    if details.get("ID") != "ubuntu" or not details.get("VERSION_ID", "").startswith("24.04"):
        raise InstallError("Эта версия установщика поддерживает чистую Ubuntu 24.04")
    if shutil.which("systemctl") is None or shutil.which("ip") is None:
        raise InstallError("Нужны systemd и iproute2; проверьте базовую Ubuntu")


def confirm(text, required):
    print("\n" + text)
    return input(f"Для подтверждения введите {required}: ").strip() == required


def choose(prompt, default):
    answer = input(f"{prompt} [{default}]: ").strip()
    return answer or default


def global_ipv6():
    result = run(["ip", "-j", "-6", "address", "show", "scope", "global"])
    found = []
    for item in json.loads(result.stdout):
        for addr in item.get("addr_info", []):
            value = addr.get("local")
            flags = set(addr.get("flags", []))
            if addr.get("family") != "inet6" or flags.intersection({"tentative", "dadfailed", "deprecated", "temporary"}):
                continue
            try:
                ip = hops.check_ip(value)
            except hops.ChainError:
                continue
            if ip not in found:
                found.append(ip)
    return found


def select_ipv6():
    options = global_ipv6()
    if not options:
        raise InstallError("Глобальный IPv6 на интерфейсах не обнаружен")
    print("\nОбнаруженные глобальные IPv6:")
    for idx, ip in enumerate(options, 1):
        print(f"  {idx}. {ip}")
    number = choose("Выберите номер адреса для VLESS-ссылки", "1")
    try:
        return options[int(number) - 1] if int(number) >= 1 else options[-999]
    except (ValueError, IndexError) as exc:
        raise InstallError("Неверный номер IPv6") from exc


def inspect_target(sni):
    try:
        with socket.create_connection((sni, 443), timeout=8) as tcp:
            context = ssl.create_default_context()
            context.minimum_version = ssl.TLSVersion.TLSv1_3
            context.set_alpn_protocols(["h2", "http/1.1"])
            with context.wrap_socket(tcp, server_hostname=sni) as tls:
                print(f"TLS target проверен: {tls.version()}, ALPN={tls.selected_alpn_protocol()}")
    except (OSError, ssl.SSLError) as exc:
        raise InstallError(f"Выбранный SNI не прошёл проверку TLS 1.3: {exc}") from exc


def ensure_port_free(address, port):
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        try:
            sock.bind((address, port))
        except OSError as exc:
            raise InstallError(f"Порт [{address}]:{port} занят или недоступен: {exc}") from exc


def ensure_clean():
    if STATE_FILE.exists():
        raise InstallError("Этот узел уже установлен; используйте status или restore")
    if MANAGED_CORE.exists():
        # A previous successful restore left our Xray binary (not a pre-existing one).
        if not XRAY.is_file() or not XRAY_UNIT.is_file():
            raise InstallError("Неполная старая установка; требуется ручная диагностика")
        active = run(["systemctl", "is-active", "--quiet", "xray"], check=False)
        if active.returncode == 0:
            raise InstallError("Xray всё ещё запущен; повторная установка запрещена")
        try:
            placeholder = json.loads(CONFIG_FILE.read_text())
        except (OSError, ValueError):
            raise InstallError("Существующая конфигурация не является пустой")
        if placeholder != {}:
            raise InstallError("Существующая конфигурация Xray изменена вручную; отказ")
        return
    if XRAY.exists() or XRAY_UNIT.exists() or CONFIG_FILE.exists():
        raise InstallError(
            "Обнаружен существующий Xray. Установщик рассчитан только на чистый VPS. "
            "Ничего не изменено."
        )


def install_core():
    print("\nСкачиваю официальную версию установщика XTLS/Xray-install, "
          "закреплённую за Git-коммитом:", INSTALL_SCRIPT_COMMIT)
    try:
        with urllib.request.urlopen(INSTALL_SCRIPT_URL, timeout=35) as response:
            data = response.read(250_001)
    except OSError as exc:
        raise InstallError(f"Не удалось скачать Xray-install: {exc}") from exc
    if len(data) > 250_000 or not data.startswith(b"#!/usr/bin/env bash\n"):
        raise InstallError("Неожиданное содержимое Xray-install; выполнение запрещено")
    with tempfile.TemporaryDirectory(prefix="kit-cascade-inst-") as folder:
        script = Path(folder) / "install-release.sh"
        script.write_bytes(data)
        script.chmod(0o700)
        # The official installer also downloads and verifies Xray releases.
        run(["bash", script, "install", "--manually-restart-later"],
            timeout=1500, capture=False)
    if not XRAY.is_file() or not XRAY_UNIT.is_file():
        raise InstallError("Официальный установщик не создал ожидаемые Xray/systemd файлы")
    run(["systemctl", "daemon-reload"])


def generate_keys():
    output = run([XRAY, "x25519"]).stdout
    fields = {}
    for line in output.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            fields[k.strip().lower().replace(" ", "")] = v.strip()
    private = fields.get("privatekey")
    public = next((v for k, v in fields.items()
                   if k.startswith("password") or k.startswith("publickey")), None)
    if not private or not public:
        raise InstallError("Xray не вернул ожидаемые PrivateKey и Password/PublicKey")
    return hops.check_key(private), hops.check_key(public)


def create_local(address, port, sni):
    private, public = generate_keys()
    return {
        "address": address, "port": port, "serverName": sni,
        "id": str(uuid.uuid4()), "shortId": secrets.token_hex(8),
        "privateKey": private, "publicKey": public,
    }


def secure_dir(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)


def write_atomic(path, data, *, mode=0o600, group=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".cascade-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.chmod(name, mode)
        if group is not None:
            os.chown(name, 0, group)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_config(config):
    group = grp.getgrnam("xray").gr_gid
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(CONFIG_FILE, hops.format_plan(config).encode(), mode=0o640, group=group)


def test_config(config):
    with tempfile.TemporaryDirectory(prefix="kit-cascade-test-") as folder:
        temporary = Path(folder) / "config.json"
        temporary.write_text(hops.format_plan(config), encoding="utf-8")
        run([XRAY, "run", "-test", "-config", temporary], timeout=30)


def rollback_config(backup):
    print("\nВыполняется безопасный откат: останавливаю Xray и восстанавливаю конфиг.")
    run(["systemctl", "stop", "xray"], check=False)
    run(["systemctl", "disable", "xray"], check=False)
    if backup and backup.is_file():
        write_atomic(CONFIG_FILE, backup.read_bytes(), mode=0o640,
                     group=grp.getgrnam("xray").gr_gid)
    elif CONFIG_FILE.exists():
        CONFIG_FILE.unlink()
    for file in (LINK_FILE, STATE_FILE):
        if file.exists():
            file.unlink()


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        part = sock.recv(n - len(buf))
        if not part:
            raise InstallError("Тестовый SOCKS5-канал закрыл соединение")
        buf += part
    return buf


def proxy_probe(uri):
    """Real VLESS handshake and HTTPS to api.ipify.org via temporary loopback SOCKS."""
    next_hop = hops.parse_link(uri)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as tmp:
        tmp.bind(("127.0.0.1", 0))
        port = tmp.getsockname()[1]
    config = {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "probe-local", "listen": "127.0.0.1", "port": port,
            "protocol": "socks", "settings": {"auth": "noauth", "udp": False},
        }],
        "outbounds": [hops.outbound(next_hop)],
    }
    with tempfile.TemporaryDirectory(prefix="kit-cascade-probe-") as folder:
        cfg = Path(folder) / "probe.json"
        cfg.write_text(hops.format_plan(config), encoding="utf-8")
        run([XRAY, "run", "-test", "-config", cfg])
        proc = subprocess.Popen(
            [str(XRAY), "run", "-config", str(cfg)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise InstallError("Временный Xray для проверки VLESS не запустился")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                        break
                except OSError:
                    time.sleep(0.2)
            else:
                raise InstallError("Временный SOCKS5-прокси не открыл порт")
            with socket.create_connection(("127.0.0.1", port), timeout=12) as s:
                s.settimeout(15)
                s.sendall(b"\x05\x01\x00")
                if read_exact(s, 2) != b"\x05\x00":
                    raise InstallError("Ошибка SOCKS5-приветствия")
                host = b"api.ipify.org"
                s.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) +
                          host + (443).to_bytes(2, "big"))
                response = read_exact(s, 4)
                if response[1] != 0 or response[0] != 5:
                    raise InstallError(f"VLESS-канал отказал в соединении, SOCKS код {response[1]}")
                atyp = response[3]
                count = {1: 4, 4: 16}.get(atyp)
                if atyp == 3:
                    count = read_exact(s, 1)[0]
                if count is None:
                    raise InstallError("Неизвестный адрес SOCKS")
                read_exact(s, count + 2)
                ctx = ssl.create_default_context()
                with ctx.wrap_socket(s, server_hostname=host.decode()) as tls:
                    tls.sendall(
                        b"GET / HTTP/1.1\r\nHost: api.ipify.org\r\n"
                        b"Accept-Encoding: identity\r\nConnection: close\r\n\r\n"
                    )
                    response = http.client.HTTPResponse(tls)
                    response.begin()
                    if response.status != 200:
                        raise InstallError(
                            f"HTTPS-проба через VLESS получила HTTP {response.status}"
                        )
                    body = response.read(256).strip()
            if not body:
                raise InstallError("HTTPS-проба вернула пустой IP")
            try:
                ipaddress.ip_address(body.decode())
            except ValueError as exc:
                raise InstallError("HTTPS-проба не вернула IP адрес") from exc
            return body.decode()
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=4)


def install(args):
    ensure_clean()
    role = args.role
    if not role:
        print("\n1. EXIT — выходной сервер")
        print("2. RELAY — промежуточный сервер")
        answer = input("Выберите роль [1]: ").strip() or "1"
        if answer not in ("1", "2"):
            raise InstallError("Неверная роль")
        role = "exit" if answer == "1" else "relay"
    address = select_ipv6()
    port = hops.check_port(choose("TCP порт для входящего VLESS", "24443"))
    ensure_port_free(address, port)
    sni = hops.check_sni(choose("SNI/REALITY target (TLS 1.3)", "www.microsoft.com"))
    inspect_target(sni)
    next_uri = None
    if role == "relay":
        next_uri = getpass.getpass(
            "Вставьте VLESS-ссылку следующего узла (ввод скрыт): "
        ).strip()
        next_hop = hops.parse_link(next_uri)
        if next_hop["address"] == address and next_hop["port"] == port:
            raise InstallError("RELAY не может ссылаться на собственный inbound")
    print("\nПлан:")
    print("  Роль:", role.upper())
    print("  Входящий IPv6/TCP:", f"[{address}]:{port}")
    print("  Маскировка:", sni)
    if next_uri:
        print("  Следующий узел:", f'[{next_hop["address"]}]:{next_hop["port"]}')
    print("  Будет установлен официальный Xray-core и изменён только его конфиг.")
    print("  SSH, маршрутизация, UFW, DNS и nftables НЕ изменяются.")
    print("  Исходящие соединения Ubuntu сами по себе НЕ туннелируются.")
    if not confirm("Продолжить установку?", "УСТАНОВИТЬ"):
        print("Отменено без изменений.")
        return
    secure_dir(STATE_DIR)
    backup = None
    core_attempted = False
    try:
        core_attempted = True
        if not MANAGED_CORE.exists():
            install_core()
            write_atomic(MANAGED_CORE, (
                "Xray установлен KIT-Cascade; после restore повторная установка разрешена.\n"
            ).encode())
        local = create_local(address, port, sni)
        config = hops.node_config(role, local, next_uri)
        test_config(config)
        saved_link = hops.link(local, "KIT-Cascade-" + role.upper())
        backup_dir = STATE_DIR / "backups" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        secure_dir(backup_dir)
        backup = backup_dir / "config.before.json"
        if CONFIG_FILE.exists():
            write_atomic(backup, CONFIG_FILE.read_bytes())
        write_config(config)
        run([XRAY, "run", "-test", "-config", CONFIG_FILE])
        run(["systemctl", "enable", "xray"])
        run(["systemctl", "restart", "xray"])
        run(["systemctl", "is-active", "--quiet", "xray"])
        print("\nПроверка настоящего VLESS-туннеля до интернета...")
        exit_ip = proxy_probe(saved_link)
        state = {
            "schema": 1, "role": role, "address": address,
            "port": port, "serverName": sni,
            "backup": str(backup), "installed": datetime.now(timezone.utc).isoformat(),
            "last_probe_exit_ip": exit_ip,
        }
        write_atomic(STATE_FILE, hops.format_plan(state).encode())
        write_atomic(LINK_FILE, (saved_link + "\n").encode())
        print("\nУстановка и контрольный HTTPS-запрос прошли успешно.")
        print("Выходной IP цепочки:", exit_ip)
        print("\nVLESS-ссылка для предыдущего узла (сохраните в защищённом месте):\n")
        print(saved_link)
        print("\nТакже доступна через sudo python3 cascade_v2/install.py show-link.")
        print("Порт должен быть открыт в файрволе провайдера: TCP/" + str(port))
        print("Для RELAY: свобода выхода только через следующий Xray на уровне прокси.")
        print("Системный kill switch пока НЕ настраивается.")
    except Exception:
        if core_attempted:
            try:
                if not MANAGED_CORE.exists() and XRAY.is_file() and XRAY_UNIT.is_file():
                    write_atomic(MANAGED_CORE, b"Managed by KIT-Cascade (partial install)\n")
                rollback_config(backup)
            except Exception as err:
                print("ВНИМАНИЕ: автоматический откат завершился ошибкой:", err,
                      file=sys.stderr)
        raise


def show_status():
    if not STATE_FILE.exists():
        print("KIT-Cascade ещё не установлен на этом сервере")
        return
    state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    print("Роль:", state["role"].upper())
    print("Вход:", f'[{state["address"]}]:{state["port"]}')
    print("SNI:", state["serverName"])
    print("Последний проверенный IP:", state.get("last_probe_exit_ip", "нет"))
    active = run(["systemctl", "is-active", "xray"], check=False)
    print("Xray service:", active.stdout.strip() or "unknown")


def restore():
    if not STATE_FILE.exists():
        raise InstallError("Нет сохранённого состояния для восстановления")
    state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    backup = Path(state["backup"])
    if not backup.is_file() or not backup.is_relative_to(STATE_DIR / "backups"):
        raise InstallError("Резервная копия отсутствует или находится вне /etc/kit-cascade")
    if not confirm("Остановить Xray и восстановить конфиг до Cascade?", "ВОССТАНОВИТЬ"):
        print("Отменено.")
        return
    rollback_config(backup)
    print("Исходный конфиг восстановлен. Установленный бинарник Xray сохранён.")
    print("SSH, маршруты и файрвол не менялись.")


def main(argv=None):
    parser = argparse.ArgumentParser(description="KIT-Cascade 2.0 EXIT/RELAY")
    sub = parser.add_subparsers(dest="action")
    install_p = sub.add_parser("install", help="Интерактивный мастер установки")
    install_p.add_argument("--role", choices=["exit", "relay"])
    sub.add_parser("status", help="Показать состояние")
    sub.add_parser("show-link", help="Показать секретную ссылку")
    sub.add_parser("restore", help="Восстановить конфиг и отключить Xray")
    args = parser.parse_args(argv)
    try:
        require_environment()
        action = args.action
        if not action:
            print("\nKIT-Cascade 2.0\n 1. Установить EXIT / RELAY\n"
                  " 2. Статус\n 3. Показать ссылку\n 4. Восстановить\n 0. Выход")
            value = input("Выбор: ").strip()
            action = {"1": "install", "2": "status", "3": "show-link",
                      "4": "restore", "0": "quit"}.get(value)
            if not action:
                raise InstallError("Неизвестный пункт меню")
            if action == "install":
                args.role = None
        if action == "install":
            install(args)
        elif action == "status":
            show_status()
        elif action == "show-link":
            if not LINK_FILE.exists():
                raise InstallError("Ссылка ещё не создана")
            print(LINK_FILE.read_text().strip())
        elif action == "restore":
            restore()
        return 0
    except (InstallError, hops.ChainError, OSError, ValueError, KeyError) as exc:
        print("ОШИБКА:", exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
