#!/usr/bin/env bash
# Measure how long traffic stops when the r1-r3 link fails.
#
#   ./lab.py up && ansible-playbook site.yml
#   ./experiments.sh both one silent silent-bfd
#   ./lab.py down
#
# r1 pings the upstream's loopback from its own loopback ten times a second.
# Five seconds in, the link fails; the result is the longest gap between replies.
set -uo pipefail
cd "$(dirname "$0")"
REPEAT=${REPEAT:-3}

SSH() { ssh -q -i admin_key -p $((2200 + $1)) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@127.0.0.1 "${@:2}"; }

converge() {
  local start=$(date +%s)
  until SSH 1 'ping -c1 -W1 -I 10.255.0.1 198.51.100.1 >/dev/null 2>&1' &&
        [ "$(SSH 3 'sudo vtysh -c "show ip ospf neighbor"' | grep -c Full)" -eq 2 ] &&
        SSH 1 'ip route get 198.51.100.1 | grep -q to-r3'; do
    sleep 2
    [ $(( $(date +%s) - start )) -gt 150 ] && { echo "the lab did not converge" >&2; exit 1; }
  done
}

bfd() {
  ansible-playbook site.yml -e "bfd=$1" >/dev/null || { echo "playbook failed" >&2; exit 1; }
  converge
  sleep 5
  # Trust nothing until the lab proves it is running the configuration you asked for.
  local sessions=$(SSH 3 'sudo vtysh -c "show bfd peers brief"' | grep -c ' up ')
  echo "BFD $1: $sessions BFD sessions up on r3"
}

measure() {
  local label=$1 secs=$2; shift 2
  sleep $(( RANDOM % 10 ))   # fail at a random point in the hello cycle
  SSH 1 "sudo ping -D -i 0.1 -c $(( secs * 10 )) -I 10.255.0.1 198.51.100.1" > ping.txt 2>&1 &
  local ping=$!
  sleep 5
  "$@"
  wait $ping
  python3 - "$label" <<'PY'
import re, sys
times = [float(t) for t in re.findall(r'^\[(\d+\.\d+)\].*bytes from', open('ping.txt').read(), re.M)]
print(f"{sys.argv[1]}: longest gap between replies {max(b - a for a, b in zip(times, times[1:])):.1f}s")
PY
}

both_down() { ./lab.py link r1 r3 off >/dev/null; ./lab.py link r3 r1 off >/dev/null; }
r1_down()   { ./lab.py link r1 r3 off >/dev/null; }
links_up()  { ./lab.py link r1 r3 on >/dev/null; ./lab.py link r3 r1 on >/dev/null; converge; }
# Both interfaces stay up; every packet on the link is dropped.
silence()   { SSH 1 'sudo tc qdisc add dev to-r3 root netem loss 100%'; SSH 3 'sudo tc qdisc add dev to-r1 root netem loss 100%'; }
unsilence() { SSH 1 'sudo tc qdisc del dev to-r3 root'; SSH 3 'sudo tc qdisc del dev to-r1 root'; converge; }

for case in "$@"; do
  case $case in
    both)       bfd false; for _ in $(seq "$REPEAT"); do measure "link down at both ends, no BFD" 20 both_down; links_up; done ;;
    one)        bfd false; for _ in $(seq "$REPEAT"); do measure "link down at r1's end only, no BFD" 20 r1_down; links_up; done ;;
    silent)     bfd false; for _ in $(seq "$REPEAT"); do measure "silent link, no BFD" 60 silence; unsilence; done ;;
    silent-bfd) bfd true;  for _ in $(seq "$REPEAT"); do measure "silent link, with BFD" 20 silence; unsilence; done ;;
    *) echo "unknown case: $case (both, one, silent, silent-bfd)" >&2; exit 1 ;;
  esac
done
rm -f ping.txt
