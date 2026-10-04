#!/usr/bin/env bash
# Two tenants on the border router, one shared upstream, and the ways a
# route leak between them goes wrong.
#
#   ./lab.py up && ansible-playbook site.yml
#   ./vrf-experiments.sh
#   ./lab.py down
#
# Everything is applied to r3 at runtime and removed at the end, so the lab
# is left as site.yml built it. Each tenant is a VRF on r3 with a host behind
# it: a network namespace on a veth pair, so traffic is forwarded through the
# VRF the way it would be from a real customer network. Tenant addresses sit
# inside 10.0.0.0/16, the aggregate r3 already announces upstream, with a
# route to Null0 behind it.
set -uo pipefail
cd "$(dirname "$0")"

SSH() { ssh -q -i admin_key -p $((2200 + $1)) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@127.0.0.1 "${@:2}"; }
R3() { SSH 3 "$@"; }
vty() { local args=(); for c in "$@"; do args+=(-c "'$c'"); done; R3 "sudo vtysh -c 'configure terminal' ${args[*]}"; }
UPSTREAM=198.51.100.1

tenant() {   # tenant VRF TABLE PREFIX   (gateway .1 on r3, host .2)
  R3 "sudo ip link add $1 type vrf table $2 && sudo ip link set $1 up &&
      sudo ip netns add $1-host &&
      sudo ip link add $1-lan type veth peer name eth0 netns $1-host &&
      sudo ip link set $1-lan master $1 && sudo ip addr add $3.1/24 dev $1-lan && sudo ip link set $1-lan up &&
      sudo ip netns exec $1-host ip link set lo up &&
      sudo ip netns exec $1-host ip addr add $3.2/24 dev eth0 &&
      sudo ip netns exec $1-host ip link set eth0 up &&
      sudo ip netns exec $1-host ip route add default via $3.1"
}
# Deleting a VRF does not empty its table: routes with no device, such as an
# unreachable default, stay behind and turn up in the next VRF given the same
# table number. So the table is flushed explicitly.
untenant() {   # untenant VRF TABLE
  R3 "sudo ip netns del $1-host; sudo ip link del $1; sudo ip route flush table $2"
}

# The kernel's VRF documentation recommends this in every VRF table, so a
# lookup that misses the VRF's own routes stops instead of carrying on.
seal() { R3 "sudo ip route add vrf $1 unreachable default metric 4278198272"; }

# Echo requests the upstream has received, and packets it has received from
# r3: the only way to tell "dropped on r3" from "left, and the reply was lost".
isp_echoes() { SSH 4 "nstat -az IcmpInEchos" | awk '/IcmpInEchos/ {print $2}'; }
isp_rx() { SSH 4 "cat /sys/class/net/to-r3/statistics/rx_packets"; }

probe() {   # probe LABEL VRF DESTINATION
  local out e0 e1 r0 r1
  e0=$(isp_echoes); r0=$(isp_rx)
  out=$(R3 "sudo ip netns exec $2-host ping -c 5 -i 0.2 -W 1 $3 2>&1")
  e1=$(isp_echoes); r1=$(isp_rx)
  printf '  %-30s %-17s upstream got %s echo requests, %s packets from r3%s\n' "$1" \
    "$(echo "$out" | grep -oE '[0-9]+% packet loss' | head -1)" "$((e1 - e0))" "$((r1 - r0))" \
    "$(echo "$out" | grep -qi 'unreachable' && echo '; r3 answered "unreachable"')"
}
fib() { R3 "sudo vtysh -c 'show ip route $1'" | grep -E '^Routing entry|Known via|blackhole|directly|via ' | head -3 | sed 's/^/      /'; }

step() { echo; echo "== $*"; sleep 1; }

step "1. Two tenants with the same address space, no leaking"
tenant red 1001 10.0.50
tenant blue 1002 10.0.50
echo "  red's table:"; R3 'ip route show vrf red' | sed 's/^/    /'
probe "red host -> upstream" red $UPSTREAM
echo "  the same, after adding the unreachable default to each VRF:"
seal red; seal blue
R3 'ip route show vrf red' | sed 's/^/    /'
probe "red host -> upstream" red $UPSTREAM

step "2. Leak the upstream's routes into red, and nothing back"
vty 'router bgp 64510 vrf red' 'bgp router-id 10.255.0.3' 'address-family ipv4 unicast' \
    'redistribute connected' 'import vrf default'
sleep 6
echo "  red's route to the upstream: $(R3 "ip route get vrf red $UPSTREAM" | head -1)"
probe "red host -> upstream" red $UPSTREAM
echo "  r3's route back to the red host (10.0.50.2), in the default VRF:"; fib 10.0.50.2

step "3. Leak red back into the default VRF as well"
vty 'router bgp 64510' 'address-family ipv4 unicast' 'import vrf red'
sleep 6
echo "  r3's route back to the red host:"; fib 10.0.50.2
probe "red host -> upstream" red $UPSTREAM

step "4. Do the same for blue, which uses the same addresses"
vty 'router bgp 64510 vrf blue' 'bgp router-id 10.255.0.3' 'address-family ipv4 unicast' \
    'redistribute connected' 'import vrf default'
vty 'router bgp 64510' 'address-family ipv4 unicast' 'import vrf blue'
sleep 6
echo "  BGP paths to 10.0.50.0/24 in the default VRF:"
R3 "sudo vtysh -c 'show ip bgp 10.0.50.0/24'" | grep -E 'Paths:|Imported from|best' | sed 's/^/    /'
echo "  r3's route back to 10.0.50.2:"; fib 10.0.50.2
probe "red host -> upstream" red $UPSTREAM
probe "blue host -> upstream" blue $UPSTREAM

step "5. Renumber blue out of the overlap"
# In place: deleting and recreating the VRF under FRR left its BGP instance
# out of step with the kernel, which is a different experiment.
R3 "sudo ip addr flush dev blue-lan && sudo ip addr add 10.0.60.1/24 dev blue-lan &&
    sudo ip netns exec blue-host ip addr flush dev eth0 &&
    sudo ip netns exec blue-host ip addr add 10.0.60.2/24 dev eth0 &&
    sudo ip netns exec blue-host ip route add default via 10.0.60.1"
sleep 8
echo "  blue's table once FRR has caught up:"; R3 'ip route show vrf blue' | sed 's/^/    /'
echo "  r3's route back to the blue host (10.0.60.2):"; fib 10.0.60.2
probe "red host -> upstream" red $UPSTREAM
probe "blue host -> upstream" blue $UPSTREAM

step "6. Can the tenants now reach each other?"
echo "  red's route to the blue host: $(R3 'ip route get vrf red 10.0.60.2' | head -1)"
probe "red host -> blue host" red 10.0.60.2

step "Cleaning up"
vty 'router bgp 64510' 'address-family ipv4 unicast' 'no import vrf red' 'no import vrf blue'
vty 'no router bgp 64510 vrf red' 'no router bgp 64510 vrf blue'
untenant red 1001; untenant blue 1002
echo "  done"
