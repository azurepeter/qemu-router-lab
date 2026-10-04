# qemu-router-lab

A four-router lab on one Linux machine: QEMU with KVM, FRRouting on Ubuntu 22.04, wired from one topology file and configured by Ansible, with links you can fail from a script.

```text
            r2
          /    \
        r1 ---- r3 ---- isp
       OSPF area 0      eBGP
```

`r1`, `r2` and `r3` run OSPF. `r3` is the border router, with an eBGP session to `isp`, which announces a default route and a loopback to ping. Every address and AS number is from documentation or private ranges.

## How it fits together

- **One topology file.** [`topology.yml`](topology.yml) lists the nodes and links. [`lab.py`](lab.py) reads it to start QEMU with the right virtual cables *and* to write the Ansible inventory, so the wiring and the configuration cannot disagree.
- **One base image, thin clones.** [`build-image.sh`](build-image.sh) builds `router-base.qcow2` by unattended install from the stock Ubuntu ISO. Each router is a qcow2 overlay on it; delete `run/` to reset the lab.
- **Cables are UDP sockets.** Each link is a pair of QEMU `dgram` sockets on `127.0.0.1`. No bridges, no TAP devices, no root on the host.
- **Management is separate.** Each router has a user-mode management NIC with SSH forwarded to `127.0.0.1:2201`–`2204`. It takes an address from DHCP but installs no routes, so it cannot become part of the data plane.
- **Failures on demand.** `./lab.py link r1 r3 off` takes `r1`'s end of a link down through the QEMU monitor. [`experiments.sh`](experiments.sh) also simulates a *silent* failure — both interfaces up, every packet dropped — with `tc netem` inside the routers.

## Requirements

- Linux or WSL2 with KVM: read-write access to `/dev/kvm`
- `qemu-system-x86`, `qemu-utils`, `xorriso`, `openssh-client`, Python 3
- [Ubuntu 22.04.4 live server ISO](https://old-releases.ubuntu.com/releases/22.04.4/) (`ubuntu-22.04.4-live-server-amd64.iso`); the build checks its SHA-256
- Ansible, from `requirements.txt`
- About 5 GB of RAM while all four routers run (4 GB while building the image), and about 7 GB of disk

## Quick start

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
. .venv/bin/activate

./build-image.sh ~/Downloads/ubuntu-22.04.4-live-server-amd64.iso   # about 7 minutes
./lab.py up                  # about 25 seconds to SSH
ansible-playbook site.yml    # interfaces, hostnames, OSPF and BGP
./experiments.sh both one silent silent-bfd
./lab.py down
```

On Debian and Ubuntu, `python3 -m venv` needs the `python3-venv` package.

To look around: `ssh -i admin_key -p 2201 admin@127.0.0.1`, then `sudo vtysh`.

## What the experiments measured

`r1` pings the upstream's loopback from its own loopback ten times a second; five seconds in, the `r1`–`r3` link fails. Each result is the longest gap between replies.

| Failure | BFD | Longest gap between replies |
|---|---|---|
| Link down at both ends | No | 1.1s, 1.1s |
| Link down at `r1`'s end only | No | 1.1s, 1.1s |
| Link silent, both ends still up | No | 31.7s, 38.6s, 39.7s |
| Link silent, both ends still up | Yes | 1.3s, 1.4s, 1.5s |

A link that is down at one end is routed around quickly: the router that noticed floods an update over its other links, and OSPF only uses a link both routers describe. A silent failure is invisible until the OSPF dead interval (40 seconds) expires — unless BFD is running.

## Two tenants on one router: VRF experiments

[`vrf-experiments.sh`](vrf-experiments.sh) turns `r3` into a router for two tenants, `red` and `blue`, sharing the upstream. Each tenant is a Linux VRF with a host behind it (a network namespace on a veth pair), addressed inside the `10.0.0.0/16` aggregate that `r3` already announces. Everything is applied at runtime and removed afterwards. Run it after `ansible-playbook site.yml`.

Each probe is five pings from a tenant host to the upstream's loopback, with the upstream's own counters showing whether the requests arrived. Measured on FRR 8.1 and kernel 5.15, the same in every clean run:

| Step | Result | What the upstream saw |
|---|---|---|
| Two tenants, same addresses, nothing leaked, **no unreachable default in the VRF table** | 100% loss | all 5 requests: traffic fell through to the main table and left |
| The same with `unreachable default metric 4278198272` in each VRF | 100% loss, `r3` answers "unreachable" | nothing |
| Upstream routes leaked into `red`, nothing leaked back | 100% loss | all 5 requests; replies died at `r3`'s Null0 route for the aggregate |
| `red` leaked back into the default VRF too | 0% loss | 5 requests |
| `blue` added with the **same** prefix, leaked both ways | `blue` 0%, `red` 100% | both tenants' requests; the default VRF can return only one of them |
| `blue` renumbered to `10.0.60.0/24` | both 0% | 5 requests each |
| `red` host pings `blue` host | 0% loss | 10 transit packets: the tenants reach each other through the upstream |

## Things this lab taught me about itself

- **Deleting a VRF does not empty its routing table.** Routes with no device, such as the unreachable default, stay behind and appear in the next VRF given the same table number. `vrf-experiments.sh` flushes the table when it removes a tenant.
- **Recreating a VRF under a running FRR left BGP out of step** with the kernel: its leaked routes were not reinstalled. The script renumbers a tenant in place instead.

- **Clones shared a `machine-id`.** The base image now empties it, so each clone generates its own on first boot.
- **The management DHCP default route beat the OSPF default.** Management interfaces now use `dhcp4-overrides: use-routes: false`.
- **`-e bfd=false` turned BFD on.** Extra vars arrive as strings, and `"false"` is truthy in Jinja; the template tests `bfd | bool`. `experiments.sh` counts BFD sessions before every case.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
