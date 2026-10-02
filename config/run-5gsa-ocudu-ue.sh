#!/bin/bash
# 5G SA: srsUE NR SA through the OCUDU gNB (ZeroMQ) against an Open5GS 5GC, then crossed host routes and a bidirectional
# ping on 10.45.0.0/16. Run with sudo: root is needed for the srsUE utun and for the routes. The OCUDU gNB does not
# need root and runs as $SUDO_USER, through the SCTP shim on UDP 9900 towards the AMF on 9899 (NGAP on the real 127.0.0.1).
#
# Preconditions: 5GC up (start-5gc-user.sh as user, plus the UPF as root in its own terminal:
#   sudo "$PREFIX/bin/open5gs-upfd" -c "$CONFDIR/open5gs-5gc/upf.yaml"
# ), the UPF utun carrying 10.45.0.1, and the configs rendered with config/render.sh into $CONFDIR.
#
# Environment, all required:
#   PREFIX     install prefix that holds bin/srsue
#   CONFDIR    directory with the rendered ocudu-5gsa/gnb.yml and srsue/ue.conf
#   LOGDIR     where the gNB and UE logs go
#   GNB        path of the OCUDU gnb binary (build/apps/gnb/gnb in the OCUDU build tree)
#   SUDO_USER  the user that runs the gNB; sudo sets it
#
# Example:
#   sudo PREFIX="$HOME/ocudu-lab/local" CONFDIR="$HOME/ocudu-lab/config" LOGDIR="$HOME/ocudu-lab/logs" \
#        GNB="$HOME/ocudu-lab/ocudu/build/apps/gnb/gnb" config/run-5gsa-ocudu-ue.sh

set -u
PREFIX="${PREFIX:?set PREFIX to the install prefix that holds bin/srsue}"
CONFDIR="${CONFDIR:?set CONFDIR to the directory with the rendered configs}"
LOGS="${LOGDIR:?set LOGDIR to the log directory}"
GNB="${GNB:?set GNB to the path of the OCUDU gnb binary}"
CFG_UE="$CONFDIR/srsue"
CFG_GNB="$CONFDIR/ocudu-5gsa/gnb.yml"
BIN="$PREFIX/bin"
SESSION="5gsa-ocudu"
GW="10.45.0.1"

[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo $0"; exit 1; }
command -v tmux >/dev/null || { echo "tmux is missing"; exit 1; }
pgrep -x open5gs-upfd >/dev/null || { echo "[error] open5gs-upfd is not running (sudo open5gs-upfd -c open5gs-5gc/upf.yaml)"; exit 1; }
pgrep -x open5gs-amfd >/dev/null || { echo "[error] open5gs-amfd is not running (start-5gc-user.sh)"; exit 1; }
RUNAS="${SUDO_USER:?run through sudo so that SUDO_USER names the user that runs the gNB}"

# ZeroMQ is REQ/REP: once a srsUE dies, the gNB serves no new client. Stop a leftover srsUE first, then restart the gNB
# as the user, not as root. SIGINT, never SIGKILL.
if pgrep -x srsue >/dev/null; then echo "[clean] stopping leftover srsue"; pkill -INT -x srsue; for i in 1 2 3 4 5 6; do sleep 1; pgrep -x srsue >/dev/null || break; done; fi
tmux kill-session -t "$SESSION" 2>/dev/null
if pgrep -x gnb >/dev/null; then echo "[clean] stopping gnb"; pkill -INT -x gnb; for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; pgrep -x gnb >/dev/null || break; done; fi
rm -f "$LOGS/ocudu-5gsa-gnb.log"
sudo -u "$RUNAS" env LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9900 LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9899 \
  nohup "$GNB" -c "$CFG_GNB" > "$LOGS/ocudu-5gsa-gnb.log" 2>&1 &
for i in $(seq 1 30); do grep -q "NG Setup Procedure\" finished successfully" "$LOGS/ocudu-5gsa-gnb.log" 2>/dev/null && break; sleep 1; done
grep -q "NG Setup Procedure\" finished successfully" "$LOGS/ocudu-5gsa-gnb.log" || { echo "[error] gnb without NG Setup within 30 s"; tail -8 "$LOGS/ocudu-5gsa-gnb.log"; exit 1; }
echo "[ok]     OCUDU gnb started as $RUNAS, NG Setup completed"
UPF_IF=$(ifconfig | awk '/^utun/{i=$1} /inet 10\.45\.0\.1 /{sub(":","",i); print i; exit}')
[ -n "$UPF_IF" ] || { echo "[error] no utun with $GW"; exit 1; }
echo "[info]   UPF utun: $UPF_IF"

wait_for() {
  local file="$1" pattern="$2" timeout="$3" label="$4" i=0
  echo "[wait]   $label"
  while [ $i -lt "$timeout" ]; do
    if [ -f "$file" ] && grep -qE -- "$pattern" "$file" 2>/dev/null; then echo "[ok]     $label"; return 0; fi
    sleep 1; i=$((i + 1))
  done
  echo "[fail]   $label did not appear within ${timeout} s"; tail -15 "$file" 2>/dev/null | sed 's/^/         /'; return 1
}

rm -f "$LOGS/ocudu-5gsa-ue.log"
tmux new-session -d -s "$SESSION" -n ue "$BIN/srsue $CFG_UE/ue.conf 2>&1 | tee -a $LOGS/ocudu-5gsa-ue.log; read"
wait_for "$LOGS/ocudu-5gsa-ue.log" "PDU Session Establishment successful|Network attach successful" 90 "UE 5G SA: registration + PDU session" || {
  echo; echo "Attach failed. tmux attach -t $SESSION; log: $LOGS/ocudu-5gsa-ue.log"; exit 1; }

UE_IP=$(grep -o "IP: [0-9.]*" "$LOGS/ocudu-5gsa-ue.log" | tail -1 | awk '{print $2}')
sleep 1
UE_IF=$(grep -o "assigned '[a-z0-9]*'" "$LOGS/ocudu-5gsa-ue.log" | tail -1 | sed "s/assigned '//;s/'//")
echo "=============================================================="
echo "Attach succeeded. UE IP: ${UE_IP:-unknown}   UE utun: ${UE_IF:-unknown}   UPF utun: $UPF_IF"
[ -n "$UE_IP" ] && [ -n "$UE_IF" ] || { echo "[error] UE IP or utun missing in the log"; exit 1; }

# Both addresses are local to this host. Without crossed host routes the kernel answers over loopback. The UPF utun
# gets the UE address as its P2P destination (XNU binds a host route for 10.45.0.1 to the utun that owns it otherwise),
# the /16 route added by the UPF is removed and two host routes send each address through the other utun, so the
# packets travel srsUE, ZeroMQ, gNB, GTP-U, UPF and back.
ifconfig "$UPF_IF" inet "$GW" "$UE_IP" netmask 255.255.255.255 && echo "[p2p]    $UPF_IF dst $UE_IP"
route -q -n delete -net 10.45.0.0/16 >/dev/null 2>&1
route -q -n delete -host "$GW" >/dev/null 2>&1
route -q -n delete -host "$UE_IP" >/dev/null 2>&1
route -n add -host "$GW" -interface "$UE_IF" >/dev/null 2>&1 && echo "[route]  $GW via $UE_IF"
route -n add -host "$UE_IP" -interface "$UPF_IF" >/dev/null 2>&1 && echo "[route]  $UE_IP via $UPF_IF"
echo; echo "10.45 routes:"; netstat -rn -f inet | grep -E "^10\.45" | sed 's/^/  /'
echo; echo "Ping UE -> GW ($UE_IP -> $GW):"; ping -c 4 -S "$UE_IP" "$GW" | tail -3 | sed 's/^/  /'
echo; echo "Ping GW -> UE ($GW -> $UE_IP):"; ping -c 4 -S "$GW" "$UE_IP" | tail -3 | sed 's/^/  /'
echo; echo "tmux session: tmux attach -t $SESSION    Stop the UE: tmux send-keys -t $SESSION C-c"
echo "=============================================================="
