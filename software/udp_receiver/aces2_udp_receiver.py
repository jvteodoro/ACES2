#!/usr/bin/env python3
"""Small UDP receiver for the ACES2 ESP32 audio stream."""

import argparse
import socket
import struct
import subprocess
import sys
import time
import wave


HEADER = struct.Struct("!IIHH")
MAGIC = 0x41434553
SAMPLE = struct.Struct("<I")


def parse_magic(value):
    """Parse a 32-bit hexadecimal device identifier."""
    digits = value.strip().lower()
    if digits.startswith("0x"):
        digits = digits[2:]
    try:
        parsed = int(digits, 16)
    except ValueError as error:
        raise argparse.ArgumentTypeError("MAGIC deve ser hexadecimal") from error
    if not digits or parsed < 0 or parsed > 0xffffffff:
        raise argparse.ArgumentTypeError("MAGIC deve caber em 32 bits")
    return parsed


def decode_pcm_frames(payload, channels):
    """Decode FPGA words ({right_s16,left_s16}) into PCM16 WAV bytes."""
    if len(payload) % SAMPLE.size:
        raise ValueError("payload length is not a whole number of PCM frames")
    if channels not in (1, 2):
        raise ValueError("channels must be 1 (left) or 2 (stereo)")

    pcm = bytearray()
    for offset in range(0, len(payload), SAMPLE.size):
        packed = SAMPLE.unpack_from(payload, offset)[0]
        left = packed & 0xffff
        right = (packed >> 16) & 0xffff
        if channels == 1:
            pcm.extend(struct.pack("<H", left))
        else:
            pcm.extend(struct.pack("<HH", left, right))
    return bytes(pcm)


def local_addresses():
    addresses = set()
    try:
        hostname = socket.gethostname()
        for address in socket.gethostbyname_ex(hostname)[2]:
            if not address.startswith("127."):
                addresses.add(address)
    except socket.gaierror:
        pass

    # UDP connect selects the interface that would be used for the LAN.
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("192.0.2.1", 9))
        address = probe.getsockname()[0]
        if not address.startswith("127."):
            addresses.add(address)
        probe.close()
    except OSError:
        pass
    return sorted(addresses)


def print_summary(stats, last_report):
    now = time.monotonic()
    elapsed = max(now - last_report, 1e-9)
    packets_delta = stats["packets"] - stats["last_packets"]
    frames_delta = stats["frames"] - stats["last_frames"]
    devices = ",".join(
        f"0x{magic:08x}:{device['packets']}p/{device['sequence_gaps']} perdas"
        for magic, device in sorted(stats["devices"].items())
    ) or "nenhum"
    print(
        "pacotes={packets} quadros_pcm={frames} "
        "taxa={rate:.1f} quadros/s perdas_seq={lost} "
        "invalidos={invalid} bytes={bytes} dispositivos=[{devices}]".format(
            packets=stats["packets"],
            frames=stats["frames"],
            rate=frames_delta / elapsed,
            lost=stats["sequence_gaps"],
            invalid=stats["invalid_packets"],
            bytes=stats["bytes"],
            devices=devices,
        ),
        flush=True,
    )
    stats["last_packets"] = stats["packets"]
    stats["last_frames"] = stats["frames"]
    return now


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0",
                        help="endereço local para escutar (padrão: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=5000,
                        help="porta UDP (padrão: 5000)")
    parser.add_argument("--magic", action="append", type=parse_magic,
                        help="MAGIC hexadecimal aceito; repita para cada dispositivo "
                             "(padrão: ACES/0x41434553)")
    parser.add_argument("--show-samples", type=int, default=4,
                        help="quantidade de amostras exibidas por pacote inicial")
    parser.add_argument("--wav", metavar="ARQUIVO",
                        help="grava as amostras recebidas em um arquivo WAV")
    parser.add_argument("--sample-rate", type=int, default=48000,
                        help="taxa do WAV em Hz (padrão: 48000)")
    parser.add_argument("--channels", type=int, choices=(1, 2), default=1,
                        help="canais intercalados no WAV (padrão: 1)")
    parser.add_argument("--sample-bits", type=int, choices=(16,), default=16,
                        help="PCM16 emitido pela FPGA (padrão: 16)")
    parser.add_argument("--fill-loss", action="store_true",
                        help="insere silêncio para pacotes UDP perdidos")
    parser.add_argument("--play", action="store_true",
                        help="reproduz o áudio recebido pelo dispositivo ALSA padrão")
    args = parser.parse_args()
    accepted_magics = set(args.magic or [MAGIC])

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
    try:
        sock.bind((args.bind, args.port))
    except OSError as error:
        print(f"erro: não foi possível abrir UDP {args.bind}:{args.port}: {error}",
              file=sys.stderr)
        return 1

    addresses = local_addresses()
    print("ACES2 UDP receiver ativo")
    print(f"escutando em: {args.bind}:{args.port}")
    print("MAGIC aceitos: " + ", ".join(
        f"0x{magic:08x}" for magic in sorted(accepted_magics)))
    if addresses:
        print("Configure no ESP32:")
        for address in addresses:
            print(f"  ACES2_UDP_DEST_IP   \"{address}\"")
    else:
        print("não foi possível determinar automaticamente o IP da rede")
    print(f"  ACES2_UDP_DEST_PORT {args.port}")
    print("Ctrl-C encerra o servidor.\n", flush=True)

    stats = {
        "packets": 0,
        "frames": 0,
        "bytes": 0,
        "invalid_packets": 0,
        "sequence_gaps": 0,
        "last_sequence": None,
        "last_packets": 0,
        "last_frames": 0,
        "devices": {},
    }
    wav_file = None
    player = None
    if args.wav:
        wav_file = wave.open(args.wav, "wb")
        wav_file.setnchannels(args.channels)
        wav_file.setsampwidth(args.sample_bits // 8)
        wav_file.setframerate(args.sample_rate)
        print(f"gravando WAV: {args.wav} ({args.sample_rate} Hz, "
              f"{args.channels} canal(is), {args.sample_bits} bits)", flush=True)
    if args.play:
        try:
            player = subprocess.Popen(
                ["aplay", "-q", "-t", "raw", "-f", f"S{args.sample_bits}_LE",
                 "-r", str(args.sample_rate), "-c", str(args.channels)],
                stdin=subprocess.PIPE,
            )
        except OSError as error:
            if wav_file is not None:
                wav_file.close()
            raise SystemExit(f"erro: não foi possível iniciar aplay: {error}")
        print("reprodução ALSA ativada pelo dispositivo padrão", flush=True)
    last_report = time.monotonic()
    printed_samples = 0

    try:
        while True:
            data, peer = sock.recvfrom(65535)
            stats["bytes"] += len(data)

            if len(data) < HEADER.size:
                stats["invalid_packets"] += 1
                continue

            magic, sequence, sample_count, flags = HEADER.unpack_from(data)
            payload = data[HEADER.size:]
            expected_size = sample_count * SAMPLE.size
            valid = (magic in accepted_magics and sample_count > 0 and
                     len(payload) == expected_size)
            if not valid:
                stats["invalid_packets"] += 1
                print(f"pacote inválido de {peer[0]}:{peer[1]}: "
                      f"bytes={len(data)} magic=0x{magic:08x} "
                      f"amostras={sample_count} "
                      f"magics_aceitos={[f'0x{x:08x}' for x in sorted(accepted_magics)]}",
                      flush=True)
                continue

            device_stats = stats["devices"].setdefault(magic, {
                "packets": 0, "frames": 0, "sequence_gaps": 0,
                "last_sequence": None,
            })
            sequence_gap = 0
            previous_sequence = device_stats["last_sequence"]
            if previous_sequence is not None:
                expected = (previous_sequence + 1) & 0xffffffff
                if sequence != expected:
                    if previous_sequence > 1024 and sequence < 1024:
                        print(f"reinício de sequência MAGIC=0x{magic:08x}: "
                              f"{previous_sequence} -> {sequence}", flush=True)
                    else:
                        gap = (sequence - expected) & 0xffffffff
                        sequence_gap = gap if gap else 1
                        stats["sequence_gaps"] += sequence_gap
                        device_stats["sequence_gaps"] += sequence_gap
                        print(f"salto de sequência MAGIC=0x{magic:08x}: "
                              f"esperado={expected} recebido={sequence}",
                              flush=True)

            device_stats["last_sequence"] = sequence
            device_stats["packets"] += 1
            device_stats["frames"] += sample_count
            stats["packets"] += 1
            stats["frames"] += sample_count

            if wav_file is not None:
                if args.fill_loss and sequence_gap:
                    missing_frames = sequence_gap * sample_count
                    silence = b"\x00" * missing_frames * args.channels * (args.sample_bits // 8)
                    if wav_file is not None:
                        wav_file.writeframes(silence)
                    if player is not None:
                        player.stdin.write(silence)
                pcm = decode_pcm_frames(payload, args.channels)
                if wav_file is not None:
                    wav_file.writeframes(pcm)
                if player is not None:
                    player.stdin.write(pcm)
                    player.stdin.flush()

            if printed_samples < args.show_samples:
                values = [SAMPLE.unpack_from(payload, offset)[0]
                          for offset in range(0, len(payload), SAMPLE.size)]
                shown = values[:args.show_samples]
                if args.channels == 2:
                    sample_text = " ".join(
                        f"L={struct.unpack('<h', struct.pack('<H', value & 0xffff))[0]} "
                        f"R={struct.unpack('<h', struct.pack('<H', value >> 16))[0]}"
                        for value in shown)
                else:
                    sample_text = " ".join(
                        str(struct.unpack('<h', struct.pack('<H', value & 0xffff))[0])
                        for value in shown)
                print(f"MAGIC=0x{magic:08x} pacote={sequence} "
                      f"quadros={sample_count} flags=0x{flags:04x} "
                      f"origem={peer[0]} PCM={sample_text}", flush=True)
                printed_samples += 1

            now = time.monotonic()
            if now - last_report >= 1.0:
                last_report = print_summary(stats, last_report)
    except KeyboardInterrupt:
        print("\nencerrando...")
        print_summary(stats, last_report)
    finally:
        if wav_file is not None:
            wav_file.close()
        if player is not None:
            player.stdin.close()
            player.wait(timeout=2)
        sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
