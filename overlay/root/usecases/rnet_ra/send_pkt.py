#!/usr/bin/env python3
# send_pkt.py

import base64
import sys
import subprocess
from scapy.all import Ether, IP, sendp, get_if_hwaddr, get_if_addr, getmacbyip

iface = "enp0s4"
packet_file = sys.argv[1] if len(sys.argv) > 1 else "/root/usecases/rnet_ra/packet.txt"

def default_gw_for_iface(iface: str) -> str | None:
    """
    Returns default gateway IP for a given interface by parsing:
      ip route show default dev <iface>
    """
    try:
        out = subprocess.check_output(
            ["ip", "route", "show", "default", "dev", iface],
            text=True
        ).strip()
    except Exception:
        return None

    # Example: "default via 10.0.2.2 dev enp0s4 ..."
    parts = out.split()
    if "via" in parts:
        return parts[parts.index("via") + 1]
    return None

with open(packet_file, "r", encoding="utf-8") as f:
    b64 = f.read().strip()

pkt = Ether(base64.b64decode(b64))

# Patch L2/L3 source to match the real egress interface
pkt[Ether].src = get_if_hwaddr(iface)
pkt[IP].src = get_if_addr(iface)

dst_ip = pkt[IP].dst

# 1) Try to ARP the destination directly (on-link case)
dst_mac = getmacbyip(dst_ip)

# 2) If not on-link, ARP the interface's default gateway
if dst_mac is None:
    gw = default_gw_for_iface(iface)
    if gw:
        dst_mac = getmacbyip(gw)

if dst_mac is None:
    raise RuntimeError(
        f"Could not resolve destination MAC. "
        f"dst_ip={dst_ip} (and gateway ARP failed on {iface}). "
        f"Check that {dst_ip} is reachable from {iface}, or set dst_mac explicitly."
    )

pkt[Ether].dst = dst_mac

# Recompute checksums/lengths after edits
del pkt[IP].len, pkt[IP].chksum
del pkt[IP].payload.len, pkt[IP].payload.chksum  # UDP len/chksum

sendp(pkt, iface=iface, verbose=False)
print(f"Sent on {iface} to L2 dst {dst_mac}, L3 dst {dst_ip}")
