#!/usr/bin/env python3
"""Run a QEMU router lab described by topology.yml.

  lab.py up                 write the inventory, create overlay disks, start every node, wait for SSH
  lab.py down               power every node off
  lab.py link A B off|on    pull or restore A's end of the A-B link
  lab.py inventory          (re)write inventory/hosts.yml for Ansible
"""
import ipaddress
import os
import socket
import subprocess
import sys
import time

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(HERE, "run")
TOPO = yaml.safe_load(open(os.path.join(HERE, "topology.yml")))
NODES = list(TOPO["nodes"])


def index(node):
    return NODES.index(node) + 1


def links():
    """Every link, with both ends worked out: interface name, MAC, address, UDP port."""
    for k, (a, b, subnet) in enumerate(TOPO["links"], start=1):
        hosts = list(ipaddress.ip_network(subnet).hosts())
        ends = []
        for side, (node, peer) in enumerate(((a, b), (b, a)), start=1):
            ends.append({
                "node": node,
                "peer": peer,
                "name": f"to-{peer}",
                "netdev": f"{node}-{peer}",
                "mac": f"52:54:00:{k:02x}:00:{index(node):02x}",
                "ip": f"{hosts[side - 1]}/{ipaddress.ip_network(subnet).prefixlen}",
                "peer_ip": str(hosts[2 - side]),
                "peer_asn": TOPO["nodes"][peer]["asn"],
                "port": 40000 + k * 10 + side,
                "peer_port": 40000 + k * 10 + (3 - side),
            })
        yield ends


def node_links(node):
    return [end for pair in links() for end in pair if end["node"] == node]


def qemu_command(node):
    i = index(node)
    cmd = [
        "qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-m", "1024", "-smp", "1",
        "-name", node, "-daemonize", "-display", "none",
        "-pidfile", f"{RUN}/{node}.pid",
        "-serial", f"file:{RUN}/{node}.log",
        "-monitor", f"unix:{RUN}/{node}.mon,server=on,wait=off",
        "-drive", f"file={RUN}/{node}.qcow2,if=virtio,format=qcow2",
        # Management: user-mode networking, SSH forwarded to a fixed host port.
        "-netdev", f"user,id=mgmt,hostfwd=tcp:127.0.0.1:{2200 + i}-:22",
        "-device", f"virtio-net-pci,netdev=mgmt,mac=52:54:00:00:00:{i:02x}",
    ]
    for end in node_links(node):
        # Each link is a pair of UDP sockets: one Ethernet segment, two ends.
        cmd += [
            "-netdev", f"dgram,id={end['netdev']},"
                       f"local.type=inet,local.host=127.0.0.1,local.port={end['port']},"
                       f"remote.type=inet,remote.host=127.0.0.1,remote.port={end['peer_port']}",
            "-device", f"virtio-net-pci,netdev={end['netdev']},mac={end['mac']}",
        ]
    return cmd


def monitor(node, command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(f"{RUN}/{node}.mon")
        s.sendall(command.encode() + b"\n")
        time.sleep(0.3)


def ssh_ready(node):
    with socket.socket() as s:
        s.settimeout(2)
        try:
            s.connect(("127.0.0.1", 2200 + index(node)))
            return s.recv(4).startswith(b"SSH")
        except OSError:
            return False


def up():
    inventory()
    os.makedirs(RUN, exist_ok=True)
    base = os.path.join(HERE, TOPO["base_image"])
    for node in NODES:
        disk = f"{RUN}/{node}.qcow2"
        if not os.path.exists(disk):
            # A thin overlay: the node's own changes on top of a base it never writes to.
            subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-b", base, "-F", "qcow2", disk], check=True)
        subprocess.run(qemu_command(node), check=True)
    start = time.time()
    while not all(ssh_ready(n) for n in NODES):
        if time.time() - start > 300:
            sys.exit("timed out waiting for SSH")
        time.sleep(2)
    print(f"all {len(NODES)} nodes answering SSH after {time.time() - start:.0f}s")


def down():
    for node in NODES:
        if os.path.exists(f"{RUN}/{node}.mon"):
            try:
                monitor(node, "system_powerdown")
            except OSError:
                pass
    for node in NODES:
        pidfile = f"{RUN}/{node}.pid"
        for _ in range(60):
            if not os.path.exists(pidfile):
                break
            time.sleep(1)
        else:
            monitor(node, "quit")
    print("all nodes stopped")


def link(a, b, state):
    monitor(a, f"set_link {a}-{b} {state}")
    print(f"{a}'s end of {a}-{b}: {state}")


def inventory():
    hosts = {}
    for node, attrs in TOPO["nodes"].items():
        hosts[node] = dict(attrs, ansible_port=2200 + index(node), links=[
            {k: end[k] for k in ("name", "mac", "ip", "peer", "peer_ip", "peer_asn")}
            for end in node_links(node)
        ])
    os.makedirs(os.path.join(HERE, "inventory"), exist_ok=True)
    with open(os.path.join(HERE, "inventory", "hosts.yml"), "w") as f:
        yaml.safe_dump({"all": {"children": {"routers": {
            "vars": {"ansible_host": "127.0.0.1", "ansible_user": "admin"},
            "hosts": hosts,
        }}}}, f, sort_keys=False)


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {"up": up, "down": down, "inventory": inventory, "link": link}[command](*args)
