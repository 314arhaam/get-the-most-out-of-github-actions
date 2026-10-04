#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="kubernetes-the-hard-way"

SSH_USER="root"

SERVER_HOST="server"
NODE_0_HOST="node-0"
NODE_1_HOST="node-1"

log() {
  echo
  echo "============================================================"
  echo "==> $*"
  echo "============================================================"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}


# ------------------------------------------------------------
# Enter repo
# ------------------------------------------------------------

if [ ! -d "$REPO_DIR" ]; then
  die "$REPO_DIR does not exist."
fi

cd "$REPO_DIR"

[ -f machines.txt ] \
  || die "machines.txt does not exist."

log "Working directory"

pwd


# ------------------------------------------------------------
# Read Pod CIDRs from machines.txt
#
# Upstream uses field 4:
#
# node-0 -> 10.200.0.0/24
# node-1 -> 10.200.1.0/24
# ------------------------------------------------------------

NODE_0_SUBNET="$(
  awk '$3 == "node-0" {print $4}' machines.txt
)"

NODE_1_SUBNET="$(
  awk '$3 == "node-1" {print $4}' machines.txt
)"

[ -n "$NODE_0_SUBNET" ] \
  || die "Could not determine node-0 Pod subnet."

[ -n "$NODE_1_SUBNET" ] \
  || die "Could not determine node-1 Pod subnet."

echo "node-0 Pod subnet: $NODE_0_SUBNET"
echo "node-1 Pod subnet: $NODE_1_SUBNET"


# ------------------------------------------------------------
# Wait for Tailnet nodes
# ------------------------------------------------------------

wait_for_host() {
  local host="$1"

  echo "Waiting for $host..."

  for attempt in {1..60}; do

    if tailscale ping \
      --timeout=2s \
      "$host" \
      >/dev/null 2>&1
    then
      echo "$host is reachable."
      return 0
    fi

    echo "$host not reachable yet. ($attempt/60)"
    sleep 2

  done

  die "Timed out waiting for $host"
}


log "Checking Tailscale connectivity"

wait_for_host "$SERVER_HOST"
wait_for_host "$NODE_0_HOST"
wait_for_host "$NODE_1_HOST"


# ------------------------------------------------------------
# Verify Tailscale SSH
# ------------------------------------------------------------

test_ssh() {
  local host="$1"

  echo "Checking SSH to $host..."

  for attempt in {1..60}; do

    if tailscale ssh \
      "${SSH_USER}@${host}" \
      "echo SSH_OK" \
      2>/dev/null |
      grep -qx SSH_OK
    then
      echo "$host SSH is ready."
      return 0
    fi

    echo "$host SSH not ready yet. ($attempt/60)"
    sleep 2

  done

  die "Unable to SSH to $host"
}


log "Checking Tailscale SSH"

test_ssh "$SERVER_HOST"
test_ssh "$NODE_0_HOST"
test_ssh "$NODE_1_HOST"


# ------------------------------------------------------------
# Discover Tailscale IPs
#
# Only informational here.
# We DON'T use them as ordinary Linux gateways.
# ------------------------------------------------------------

get_ts_ip() {
  local host="$1"

  tailscale ssh \
    "${SSH_USER}@${host}" \
    "tailscale ip -4 | head -n1"
}

SERVER_IP="$(get_ts_ip "$SERVER_HOST")"
NODE_0_IP="$(get_ts_ip "$NODE_0_HOST")"
NODE_1_IP="$(get_ts_ip "$NODE_1_HOST")"

log "Tailscale node addresses"

echo "server : $SERVER_IP"
echo "node-0 : $NODE_0_IP"
echo "node-1 : $NODE_1_IP"


# ------------------------------------------------------------
# Enable IPv4 forwarding on workers
#
# Workers are now effectively subnet routers for their Pod CIDR.
# ------------------------------------------------------------

log "Enabling IPv4 forwarding on workers"

for host in "$NODE_0_HOST" "$NODE_1_HOST"; do

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    cat > /etc/sysctl.d/99-kubernetes-tailscale.conf <<EOF
net.ipv4.ip_forward = 1
EOF

    sysctl -p /etc/sysctl.d/99-kubernetes-tailscale.conf

    test "$(sysctl -n net.ipv4.ip_forward)" = "1"
  '

done


# ------------------------------------------------------------
# Advertise each worker Pod CIDR
#
# node-0 owns:
#
#   10.200.0.0/24
#
# node-1 owns:
#
#   10.200.1.0/24
#
# This is the Tailscale equivalent of saying:
#
#   10.200.0.0/24 via node-0
#   10.200.1.0/24 via node-1
# ------------------------------------------------------------

log "Advertising Pod CIDRs through Tailscale"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
  "tailscale set --advertise-routes='${NODE_0_SUBNET}'"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
  "tailscale set --advertise-routes='${NODE_1_SUBNET}'"


# ------------------------------------------------------------
# Enable route acceptance
#
# server needs both routes.
#
# node-0 needs node-1's route.
# node-1 needs node-0's route.
#
# Tailscale will avoid replacing the node's own connected CNI
# network with its advertised route.
# ------------------------------------------------------------

log "Enabling Tailscale route acceptance"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "tailscale set --accept-routes=true"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
  "tailscale set --accept-routes=true"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
  "tailscale set --accept-routes=true"


# ------------------------------------------------------------
# IMPORTANT
#
# Advertised subnet routes must be approved in the tailnet.
#
# For CI this should normally be handled using Tailscale
# autoApprovers for tag:ci.
#
# The loop below waits until the routes actually appear.
# ------------------------------------------------------------

log "Waiting for Tailscale Pod routes"


wait_for_route() {
  local host="$1"
  local subnet="$2"

  echo "Waiting on $host for route $subnet..."

  for attempt in {1..90}; do

    if tailscale ssh "${SSH_USER}@${host}" \
      "ip route show table 52 | grep -Fq '${subnet}'"
    then
      echo "$host has route $subnet."
      return 0
    fi

    echo "Route not available yet. ($attempt/90)"
    sleep 2

  done

  echo
  echo "Tailscale table 52 on $host:"

  tailscale ssh "${SSH_USER}@${host}" \
    "ip route show table 52 || true"

  die "Route $subnet did not appear on $host."
}


# server must know both worker Pod networks

wait_for_route \
  "$SERVER_HOST" \
  "$NODE_0_SUBNET"

wait_for_route \
  "$SERVER_HOST" \
  "$NODE_1_SUBNET"


# node-0 only needs remote Pod network

wait_for_route \
  "$NODE_0_HOST" \
  "$NODE_1_SUBNET"


# node-1 only needs remote Pod network

wait_for_route \
  "$NODE_1_HOST" \
  "$NODE_0_SUBNET"


# ------------------------------------------------------------
# Show routing tables
# ------------------------------------------------------------

log "Server Tailscale routing table"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "ip route show table 52"


log "node-0 routing"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}" '
  echo "Main table:"
  ip route

  echo
  echo "Tailscale table 52:"
  ip route show table 52
'


log "node-1 routing"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}" '
  echo "Main table:"
  ip route

  echo
  echo "Tailscale table 52:"
  ip route show table 52
'


# ------------------------------------------------------------
# Route lookup verification
# ------------------------------------------------------------

log "Checking route decisions"

NODE_0_TEST_IP="$(
  python3 - <<PY
import ipaddress
net = ipaddress.ip_network("${NODE_0_SUBNET}")
print(net.network_address + 10)
PY
)"

NODE_1_TEST_IP="$(
  python3 - <<PY
import ipaddress
net = ipaddress.ip_network("${NODE_1_SUBNET}")
print(net.network_address + 10)
PY
)"


echo "node-0 test Pod IP: $NODE_0_TEST_IP"
echo "node-1 test Pod IP: $NODE_1_TEST_IP"


echo
echo "server -> node-0 Pod network"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "ip route get '${NODE_0_TEST_IP}'"


echo
echo "server -> node-1 Pod network"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "ip route get '${NODE_1_TEST_IP}'"


echo
echo "node-0 -> node-1 Pod network"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
  "ip route get '${NODE_1_TEST_IP}'"


echo
echo "node-1 -> node-0 Pod network"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
  "ip route get '${NODE_0_TEST_IP}'"


# ------------------------------------------------------------
# Verify forwarding
# ------------------------------------------------------------

log "Checking worker forwarding"

for host in "$NODE_0_HOST" "$NODE_1_HOST"; do

  echo -n "$host IPv4 forwarding: "

  tailscale ssh "${SSH_USER}@${host}" \
    "sysctl -n net.ipv4.ip_forward"

done


# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

log "Pod network routes configured"

echo
echo "Routing topology:"
echo
echo "  node-0"
echo "    Pod CIDR : $NODE_0_SUBNET"
echo "    Tailnet  : $NODE_0_IP"
echo
echo "  node-1"
echo "    Pod CIDR : $NODE_1_SUBNET"
echo "    Tailnet  : $NODE_1_IP"
echo
echo "  server"
echo "    Tailnet  : $SERVER_IP"
echo
echo "Tailscale routing table:"
echo "  table 52"