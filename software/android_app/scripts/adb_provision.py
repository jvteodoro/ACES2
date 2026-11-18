#!/usr/bin/env python3
"""Drive the Android configurator over ADB for repeatable ESP32 bring-up."""

import argparse
import ipaddress
import re
import socket
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = APP_DIR.parents[1]
PACKAGE = "br.com.aces2.configurator"
BLE_CONFIG = REPO_ROOT / "software/esp32/main/provisioning_config.h"


def run(command, *, capture=True, check=True):
    return subprocess.run(
        command, check=check, text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    ).stdout if capture else ""


def auto_destination_ip():
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        return probe.getsockname()[0]
    finally:
        probe.close()


def read_ble_password(path):
    text = path.read_text(encoding="utf-8")
    match = re.search(
        r'^\s*#define\s+ACES2_BLE_SETUP_PASSWORD\s+"([^"\r\n]+)"',
        text, re.MULTILINE,
    )
    if not match:
        raise RuntimeError(f"Senha BLE não encontrada em {path}")
    password = match.group(1)
    if len(password) < 16:
        raise RuntimeError("A senha BLE configurada tem menos de 16 caracteres")
    return password


class Device:
    def __init__(self, serial=None):
        self.serial = serial

    def adb(self, *args):
        command = ["adb"]
        if self.serial:
            command += ["-s", self.serial]
        command += list(args)
        return run(command)

    def tap(self, x, y):
        self.adb("shell", "input", "tap", str(x), str(y))

    def swipe(self, x1, y1, x2, y2):
        self.adb("shell", "input", "swipe", str(x1), str(y1),
                 str(x2), str(y2), "350")

    def hierarchy(self):
        self.adb("shell", "uiautomator", "dump", "/sdcard/aces2-window.xml")
        return ET.fromstring(self.adb("shell", "cat", "/sdcard/aces2-window.xml"))

    @staticmethod
    def nodes(root):
        return list(root.iter("node"))

    @staticmethod
    def bounds(node):
        values = [int(value) for value in re.findall(r"\d+", node.get("bounds", ""))]
        if len(values) != 4:
            raise RuntimeError("Não foi possível ler a posição do controle Android")
        left, top, right, bottom = values
        return (left + right) // 2, (top + bottom) // 2

    def find_visible(self, *, hint=None, text=None, direction="down", attempts=8):
        size = self.adb("shell", "wm", "size")
        match = re.search(r"(\d+)x(\d+)", size)
        width, height = (int(match.group(1)), int(match.group(2))) if match else (1080, 2340)
        for _ in range(attempts):
            root = self.hierarchy()
            for node in self.nodes(root):
                if hint is not None and node.get("hint") == hint:
                    return node
                if text is not None and node.get("text") == text:
                    return node
            if direction == "up":
                self.swipe(width // 2, int(height * 0.22), width // 2, int(height * 0.82))
            else:
                self.swipe(width // 2, int(height * 0.82), width // 2, int(height * 0.22))
        return None

    def set_text_field(self, hint, value, direction):
        node = self.find_visible(hint=hint, direction=direction)
        if node is None:
            raise RuntimeError(f"Campo não encontrado no app: {hint}")
        x, y = self.bounds(node)
        old_text = node.get("text", "")
        self.tap(x, y)
        self.adb("shell", "input", "keyevent", "KEYCODE_MOVE_END")
        if old_text:
            self.adb("shell", "input", "keyevent",
                     *(["KEYCODE_DEL"] * len(old_text)))
        self.adb("shell", "input", "text", value.replace(" ", "%s"))
        self.adb("shell", "input", "keyevent", "KEYCODE_BACK")

    def visible_texts(self):
        return [node.get("text", "") for node in self.nodes(self.hierarchy())
                if node.get("text")]

    def wait_for(self, predicate, timeout, description):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            texts = self.visible_texts()
            result = predicate(texts)
            if result:
                return result
            time.sleep(0.8)
        raise RuntimeError(f"Tempo esgotado aguardando {description}")


def ensure_device(serial):
    output = run(["adb", "devices"], check=False)
    devices = [line.split()[0] for line in output.splitlines()[1:]
               if line.strip().endswith("device")]
    if serial:
        if serial not in devices:
            raise RuntimeError(f"Dispositivo ADB não conectado: {serial}")
        return serial
    if len(devices) != 1:
        raise RuntimeError("Conecte um único Android ou passe --device SERIAL")
    return devices[0]


def ensure_metro(device):
    metro_ready = False
    try:
        with urllib.request.urlopen("http://127.0.0.1:8081/status", timeout=1) as response:
            metro_ready = response.status == 200
    except Exception:
        metro_ready = False
    if not metro_ready:
        log_path = Path("/tmp/aces2-metro.log")
        log_file = log_path.open("w", encoding="utf-8")
        subprocess.Popen(
            ["npx", "expo", "start", "--dev-client", "--localhost", "--port", "8081"],
            cwd=APP_DIR, stdout=log_file, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        deadline = time.monotonic() + 45
        metro_ready = False
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen("http://127.0.0.1:8081/status", timeout=1) as response:
                    if response.status == 200:
                        metro_ready = True
                        break
            except Exception:
                time.sleep(1)
        if not metro_ready:
            raise RuntimeError(f"Metro não iniciou; veja {log_path}")
    device.adb("reverse", "tcp:8081", "tcp:8081")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="serial ADB; omitido se houver um único aparelho")
    parser.add_argument("--destination-ip", default="auto",
                        help="IP do computador com UDP_Receiver (padrão: interface de saída)")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--magic", default="41434553",
                        help="MAGIC hexadecimal de 32 bits, com ou sem 0x")
    parser.add_argument("--ble-config", type=Path, default=BLE_CONFIG,
                        help="arquivo local provisioning_config.h; a senha não é exibida")
    parser.add_argument("--prepare-only", action="store_true",
                        help="preencher os campos e conectar, mas não salvar no ESP32")
    args = parser.parse_args()

    serial = ensure_device(args.device)
    device = Device(serial)
    ensure_metro(device)
    device.adb("shell", "monkey", "-p", PACKAGE, "1")
    time.sleep(2)

    ip = auto_destination_ip() if args.destination_ip == "auto" else args.destination_ip
    ipaddress.IPv4Address(ip)
    if not 1 <= args.port <= 65535:
        raise RuntimeError("A porta UDP deve estar entre 1 e 65535")
    digits = args.magic.lower().removeprefix("0x")
    if not re.fullmatch(r"[0-9a-f]{1,8}", digits):
        raise RuntimeError("MAGIC deve ter de 1 a 8 dígitos hexadecimais")
    magic = digits.upper().zfill(8)
    ble_password = read_ble_password(args.ble_config)

    # Keep the SSID and Wi-Fi password the user entered in the app; only verify
    # that both are present. The local BLE key supplies the authentication field.
    device.adb("shell", "input", "keyevent", "KEYCODE_BACK")
    ssid = device.find_visible(hint="SSID / nome da rede", direction="up")
    wifi_password = device.find_visible(hint="Senha do Wi-Fi", direction="up")
    if ssid is None or not ssid.get("text") or wifi_password is None or not wifi_password.get("text"):
        raise RuntimeError("Preencha SSID e senha Wi-Fi no app antes de executar este script")

    device.set_text_field("Senha de configuração BLE", ble_password, "up")
    device.set_text_field("IP do computador, ex. 192.168.1.20", ip, "down")
    device.set_text_field("Porta UDP (padrão 5000)", str(args.port), "down")
    device.set_text_field("ID/MAGIC hexadecimal, ex. 41434553", magic, "down")
    print(f"Campos preparados: UDP {ip}:{args.port}, MAGIC 0x{magic}; senha BLE omitida.")

    texts = device.visible_texts()
    if not any(text.startswith("Conectado.") for text in texts):
        button = device.find_visible(text="Localizar ESP32", direction="up")
        if button is None:
            button = device.find_visible(text="Reconectar ao ESP32", direction="up")
        if button is None:
            raise RuntimeError("Botão de conexão BLE não encontrado")
        device.tap(*device.bounds(button))
        status = device.wait_for(
            lambda values: next((value for value in values
                                 if value.startswith(("Conectado.", "Falha na busca BLE:",
                                                      "ESP32 não encontrado.",
                                                      "Não foi possível conectar:"))), None),
            20, "conexão BLE",
        )
        print(status)
        if not status.startswith("Conectado."):
            return 2

    if args.prepare_only:
        print("Conectado; campos prontos. Salvamento omitido (--prepare-only).")
        return 0

    button = device.find_visible(text="Autenticar e salvar no ESP32", direction="down")
    if button is None:
        raise RuntimeError("Botão de salvamento não encontrado")
    device.tap(*device.bounds(button))
    status = device.wait_for(
        lambda values: next((value for value in values
                             if value.startswith(("Configuração salva no ESP32.",
                                                  "Não foi possível salvar:",
                                                  "Senha BLE incorreta;",
                                                  "Falha na autenticação BLE:"))), None),
        12, "resultado do provisionamento",
    )
    print(status)
    return 0 if status.startswith("Configuração salva no ESP32.") else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, RuntimeError, ValueError) as error:
        print(f"erro: {error}", file=sys.stderr)
        raise SystemExit(1)
