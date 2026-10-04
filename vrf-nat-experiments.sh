#!/usr/bin/env bash
# Two tenants with the same addresses sharing one upstream, made to work with
# NAT, and what NAT needs to know on the way back.
#
#   ./lab.py up && ansible-playbook site.yml
#   ./vrf-nat-experiments.sh
#   ./lab.py down
#
# Both tenants use 10.0.50.0/24. Each gets the upstream's routes leaked in,
# but nothing is leaked back: the default VRF could hold only one route to
# 10.0.50.0/24 (see vrf-experiments.sh), so the way back has to come from NAT.
# Pools: red 10.0.151.1, blue 10.0.152.1, both inside the 10.0.0.0/16
# aggregate r3 announces. Everything is removed at the end.
set -uo pipefail
cd "$(dirname "$0")"

SSH() { ssh -q -i admin_key -p $((2200 + $1)) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@127.0.0.1 "${@:2}"; }
R3() { SSH 3 "$@"; }
vty() { local args=(); for c in "$@"; do args+=(-c "'$c'"); done; R3 "sudo vtysh -c 'configure terminal' ${args[*]}"; }
UPSTREAM=198.51.100.1

tenant() {   # tenant VRF TABLE PREFIX
  R3 "sudo ip link add $1 type vrf table $2 && sudo ip link set $1 up &&
      sudo ip route add vrf $1 unreachable default metric 4278198272 &&
      sudo ip netns add $1-host &&
      sudo ip link add $1-lan type veth peer name eth0 netns $1-host &&
      sudo ip link set $1-lan master $1 && sudo ip addr add $3.1/24 dev $1-lan && sudo ip link set $1-lan up &&
      sudo ip netns exec $1-host ip link set lo up &&
      sudo ip netns exec $1-host ip addr add $3.2/24 dev eth0 &&
      sudo ip netns exec $1-host ip link set eth0 up &&
      sudo ip netns exec $1-host ip route add default via $3.1"
  vty "router bgp 64510 vrf $1" 'bgp router-id 10.255.0.3' 'address-family ipv4 unicast' 'import vrf default'
}

isp_echoes() { SSH 4 "nstat -az IcmpInEchos" | awk '/IcmpInEchos/ {print $2}'; }
summary() { grep -oE '[0-9]+ received|[0-9]+% packet loss|\+[0-9]+ duplicates' | paste -sd' '; }

probe() {   # probe LABEL VRF
  local e0 e1 out
  e0=$(isp_echoes)
  out=$(R3 "sudo ip netns exec $2-host ping -c 5 -i 0.2 -W 1 $UPSTREAM 2>&1")
  e1=$(isp_echoes)
  printf '  %-12s %-40s upstream got %s requests\n' "$1" "$(echo "$out" | summary)" "$((e1 - e0))"
}

# Both tenants at once, with the same ICMP identifier, so the two flows have
# identical tuples until NAT rewrites them. ping on this release cannot set
# the identifier, so a raw socket does it: ten requests, then a count of the
# replies that came back with that identifier.
ICMP_PY='
import socket, struct, sys, time
dst, ident = sys.argv[1], 4242
def csum(b):
    s = sum(struct.unpack("!%dH" % (len(b) // 2), b))
    s = (s >> 16) + (s & 0xFFFF); s += s >> 16
    return ~s & 0xFFFF
s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
s.settimeout(0.2)
replies, end = 0, time.time() + 4
for seq in range(10):
    hdr = struct.pack("!BBHHH", 8, 0, 0, ident, seq)
    s.sendto(struct.pack("!BBHHH", 8, 0, csum(hdr), ident, seq), (dst, 0))
    time.sleep(0.2)
while time.time() < end:
    try:
        pkt = s.recv(1500)
    except socket.timeout:
        continue
    typ, _, _, rid, _ = struct.unpack("!BBHHH", pkt[20:28])
    if typ == 0 and rid == ident:
        replies += 1
print("10 sent, %d replies" % replies)
'
together() {
  R3 "cat > /tmp/icmp.py" <<< "$ICMP_PY"
  R3 "sudo ip netns exec red-host python3 /tmp/icmp.py $UPSTREAM > /tmp/red.txt 2>&1 &
      sudo ip netns exec blue-host python3 /tmp/icmp.py $UPSTREAM > /tmp/blue.txt 2>&1 &
      wait"
  printf '  %-12s %s\n' "red" "$(R3 'cat /tmp/red.txt')"
  printf '  %-12s %s\n' "blue" "$(R3 'cat /tmp/blue.txt')"
}

fib() { R3 "sudo vtysh -c 'show ip route $1'" | grep -E '^Routing entry|blackhole|directly' | head -2 | paste -sd' ' | sed 's/^/  route for /'; }
step() { echo; echo "== $*"; sleep 1; }

step "0. Both tenants on 10.0.50.0/24, upstream routes leaked in, nothing leaked back"
tenant red 1001 10.0.50
tenant blue 1002 10.0.50
sleep 6
probe red red; probe blue blue
fib 10.0.50.2

step "1. One SNAT rule for the shared range, one public address"
R3 "sudo iptables -t nat -A POSTROUTING -o to-isp -s 10.0.50.0/24 -j SNAT --to-source 10.0.150.1"
probe red red; probe blue blue
R3 "sudo iptables -t nat -F POSTROUTING"

step "2. A pool per tenant, chosen by the interface the traffic arrived on"
R3 "sudo iptables -t mangle -A PREROUTING -i red-lan  -j CONNMARK --set-mark 1 &&
    sudo iptables -t mangle -A PREROUTING -i blue-lan -j CONNMARK --set-mark 2 &&
    sudo iptables -t nat -A POSTROUTING -o to-isp -m connmark --mark 1 -j SNAT --to-source 10.0.151.1 &&
    sudo iptables -t nat -A POSTROUTING -o to-isp -m connmark --mark 2 -j SNAT --to-source 10.0.152.1"
probe red red; probe blue blue

step "3. Route the replies by the connection's tenant, not by their address"
R3 "sudo iptables -t mangle -A PREROUTING -i to-isp -j CONNMARK --restore-mark &&
    sudo ip rule add fwmark 1 lookup 1001 pref 900 &&
    sudo ip rule add fwmark 2 lookup 1002 pref 901"
probe red red; probe blue blue

step "4. Both at once, with the same ICMP identifier"
together

step "5. The same, with each tenant's connections in their own conntrack zone"
R3 "sudo iptables -t raw -A PREROUTING -i red-lan  -j CT --zone-orig 1 &&
    sudo iptables -t raw -A PREROUTING -i blue-lan -j CT --zone-orig 2"
sleep 3
together

step "Cleaning up"
R3 "sudo iptables -t raw -F PREROUTING; sudo iptables -t mangle -F PREROUTING; sudo iptables -t nat -F POSTROUTING
    sudo ip rule del pref 900; sudo ip rule del pref 901"
vty 'no router bgp 64510 vrf red' 'no router bgp 64510 vrf blue'
R3 "sudo ip netns del red-host; sudo ip netns del blue-host; sudo ip link del red; sudo ip link del blue
    sudo ip route flush table 1001; sudo ip route flush table 1002"
echo "  done"
