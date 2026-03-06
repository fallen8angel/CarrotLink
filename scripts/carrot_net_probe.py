#!/usr/bin/env python3
"""
CarrotLink network probe utility.

Use cases:
1) Scan a local CIDR and identify likely openpilot/comma hosts.
2) Inspect an openpilot host and list current TCP peers connected to :7712.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import http.client
import ipaddress
import json
import re
import socket
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


IP_RE = re.compile(r"(\d{1,3}(?:\.\d{1,3}){3}):(\d+)")


@dataclass
class HostProbe:
  ip: str
  open_ports: list[int]
  sidecar_health: dict[str, Any] | None
  ssh_banner: str | None


def _check_tcp_port(ip: str, port: int, timeout_s: float) -> bool:
  sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  sock.settimeout(timeout_s)
  try:
    return sock.connect_ex((ip, port)) == 0
  except Exception:
    return False
  finally:
    try:
      sock.close()
    except Exception:
      pass


def _read_ssh_banner(ip: str, timeout_s: float) -> str | None:
  sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  sock.settimeout(timeout_s)
  try:
    if sock.connect_ex((ip, 22)) != 0:
      return None
    raw = sock.recv(256)
    text = raw.decode("utf-8", errors="ignore").strip()
    return text or None
  except Exception:
    return None
  finally:
    try:
      sock.close()
    except Exception:
      pass


def _fetch_sidecar_health(ip: str, timeout_s: float) -> dict[str, Any] | None:
  conn = http.client.HTTPConnection(ip, 7766, timeout=timeout_s)
  try:
    conn.request("GET", "/health")
    resp = conn.getresponse()
    body = resp.read(32768)
    if resp.status < 200 or resp.status >= 300:
      return None
    data = json.loads(body.decode("utf-8", errors="ignore"))
    if isinstance(data, dict):
      return data
    return None
  except Exception:
    return None
  finally:
    try:
      conn.close()
    except Exception:
      pass


def _probe_host(ip: str, ports: list[int], timeout_s: float) -> HostProbe:
  open_ports: list[int] = []
  for port in ports:
    if _check_tcp_port(ip, port, timeout_s):
      open_ports.append(port)
  health = _fetch_sidecar_health(ip, timeout_s) if 7766 in open_ports else None
  banner = _read_ssh_banner(ip, timeout_s) if 22 in open_ports else None
  return HostProbe(
    ip=ip,
    open_ports=open_ports,
    sidecar_health=health,
    ssh_banner=banner,
  )


def scan_cidr(
  cidr: str,
  ports: list[int],
  timeout_s: float,
  workers: int,
  show_all: bool,
) -> list[HostProbe]:
  net = ipaddress.ip_network(cidr, strict=False)
  ips = [str(ip) for ip in net.hosts()]
  if not ips:
    return []

  out: list[HostProbe] = []
  with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
    futures = [pool.submit(_probe_host, ip, ports, timeout_s) for ip in ips]
    for fut in concurrent.futures.as_completed(futures):
      result = fut.result()
      if show_all or result.open_ports:
        out.append(result)
  out.sort(key=lambda x: tuple(int(v) for v in x.ip.split(".")))
  return out


def _run_ssh(
  ssh_bin: str,
  key_path: str,
  user: str,
  host: str,
  cmd: str,
  timeout_s: float,
) -> str:
  key = str(Path(key_path).expanduser().resolve())
  args = [
    ssh_bin,
    "-o",
    "BatchMode=yes",
    "-o",
    "StrictHostKeyChecking=no",
    "-i",
    key,
    f"{user}@{host}",
    cmd,
  ]
  proc = subprocess.run(
    args,
    capture_output=True,
    text=True,
    timeout=timeout_s,
    check=False,
  )
  if proc.returncode != 0:
    err = proc.stderr.strip() or proc.stdout.strip() or "ssh failed"
    raise RuntimeError(err)
  return proc.stdout


def inspect_comma_7712(
  ssh_bin: str,
  key_path: str,
  user: str,
  host: str,
  timeout_s: float,
) -> dict[str, Any]:
  raw_ss = _run_ssh(
    ssh_bin=ssh_bin,
    key_path=key_path,
    user=user,
    host=host,
    cmd="ss -tn 2>/dev/null | grep ESTAB | grep ':7712' || true",
    timeout_s=timeout_s,
  )
  peers: list[str] = []
  for line in raw_ss.splitlines():
    matches = IP_RE.findall(line)
    if len(matches) < 2:
      continue
    a_ip, a_port = matches[0]
    b_ip, b_port = matches[1]
    if a_port == "7712":
      peers.append(b_ip)
    elif b_port == "7712":
      peers.append(a_ip)
  peers = sorted(set(peers))

  raw_tmux = _run_ssh(
    ssh_bin=ssh_bin,
    key_path=key_path,
    user=user,
    host=host,
    cmd=(
      "tmux capture-pane -pt comma:0 -S -300 2>/dev/null | "
      "grep -E 'Connected:|Received points:|Waiting for data' | tail -n 60 || true"
    ),
    timeout_s=timeout_s,
  )
  return {
    "host": host,
    "peers7712": peers,
    "ssLines": [ln for ln in raw_ss.splitlines() if ln.strip()],
    "tmuxTail": [ln for ln in raw_tmux.splitlines() if ln.strip()],
  }


def _print_scan(rows: list[HostProbe]) -> None:
  if not rows:
    print("No hosts matched.")
    return
  print("IP              PORTS            SIDEcar   SSH")
  print("-" * 62)
  for row in rows:
    ports = ",".join(str(p) for p in row.open_ports) if row.open_ports else "-"
    sidecar = "yes" if row.sidecar_health else "-"
    ssh = row.ssh_banner or "-"
    if len(ssh) > 28:
      ssh = ssh[:28] + "..."
    print(f"{row.ip:<15} {ports:<16} {sidecar:<8} {ssh}")


def parse_args() -> argparse.Namespace:
  p = argparse.ArgumentParser(
    description="Scan local IP range and inspect comma 7712 peers."
  )
  p.add_argument("--cidr", help="CIDR to scan, e.g. 192.168.50.0/24")
  p.add_argument(
    "--ports",
    default="22,7766,7712",
    help="comma-separated TCP ports to probe",
  )
  p.add_argument("--timeout-ms", type=int, default=350, help="socket timeout ms")
  p.add_argument("--workers", type=int, default=80, help="scan worker count")
  p.add_argument("--show-all", action="store_true", help="show all hosts in CIDR")
  p.add_argument("--json", action="store_true", help="json output")

  p.add_argument("--comma-host", help="comma host to inspect 7712 peers")
  p.add_argument("--ssh-user", default="comma", help="ssh user for comma inspect")
  p.add_argument("--ssh-key", help="ssh private key path for comma inspect")
  p.add_argument("--ssh-bin", default="ssh", help="ssh binary path")
  return p.parse_args()


def main() -> int:
  args = parse_args()
  timeout_s = max(0.05, args.timeout_ms / 1000.0)
  ports = []
  for token in str(args.ports).split(","):
    token = token.strip()
    if not token:
      continue
    try:
      val = int(token)
    except ValueError:
      print(f"Invalid port: {token}", file=sys.stderr)
      return 2
    if val <= 0 or val > 65535:
      print(f"Invalid port range: {val}", file=sys.stderr)
      return 2
    ports.append(val)

  if not args.cidr and not args.comma_host:
    print("Use --cidr and/or --comma-host.", file=sys.stderr)
    return 2

  payload: dict[str, Any] = {}
  if args.cidr:
    scan_rows = scan_cidr(
      cidr=args.cidr,
      ports=ports,
      timeout_s=timeout_s,
      workers=max(1, int(args.workers)),
      show_all=bool(args.show_all),
    )
    payload["scan"] = [
      {
        "ip": row.ip,
        "openPorts": row.open_ports,
        "sidecarHealth": row.sidecar_health,
        "sshBanner": row.ssh_banner,
      }
      for row in scan_rows
    ]
    if not args.json:
      _print_scan(scan_rows)

  if args.comma_host:
    if not args.ssh_key:
      print("--comma-host requires --ssh-key", file=sys.stderr)
      return 2
    inspect = inspect_comma_7712(
      ssh_bin=args.ssh_bin,
      key_path=args.ssh_key,
      user=args.ssh_user,
      host=args.comma_host,
      timeout_s=max(2.0, timeout_s * 10.0),
    )
    payload["comma7712"] = inspect
    if not args.json:
      print("")
      print(f"comma host: {inspect['host']}")
      print(f"peers7712 : {', '.join(inspect['peers7712']) if inspect['peers7712'] else '-'}")
      if inspect["tmuxTail"]:
        print("tmux tail :")
        for line in inspect["tmuxTail"][-20:]:
          print(f"  {line}")

  if args.json:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
