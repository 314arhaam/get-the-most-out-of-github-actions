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

if [ ! -d "$REPO_DIR" ]; then
  die "$REPO_DIR does not exist."
fi

cd "$REPO_DIR"

[ -f machines.txt ] || die "machines.txt does not exist."

log "Working directory"
pwd

log "Checking required commands"

for command in tailscale awk grep ip python3; do
  command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

NODE_0_SUBNET="$(awk '$3 == "node-0" {print $4}' machines.txt)"
NODE_1_SUBNET="$(awk '$3 == "node-1" {print $4}' machines.txt)"

[ -n "$NODE_0_SUBNET" ] || die "Could not determine node-0 Pod subnet."
[ -n "$NODE_1_SUBNET" ] || die "Could not determine node-1 Pod subnet."

echo "node-0 Pod subnet: $NODE_0_SUBNET"
echo "node-1 Pod subnet: $NODE_1_SUBNET"

wait_for_host() {
  local host="$1"

  echo "Waiting for $host..."

  for attempt in {1..60}; do
    if tailscale ping --timeout=2s "$host" >/dev/null 2>&1; then
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

test_ssh() {
  local host="$1"

  echo "Checking Tailscale SSH to $host..."

  for attempt in {1..60}; do
    if tailscale ssh "${SSH_USER}@${host}" "echo SSH_OK" 2>/dev/null | grep -qx "SSH_OK"; then
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

get_ts_ip() {
  local host="$1"
  tailscale ssh "${SSH_USER}@${host}" "tailscale ip -4 | head -n1"
}

SERVER_IP="$(get_ts_ip "$SERVER_HOST")"
NODE_0_IP="$(get_ts_ip "$NODE_0_HOST")"
NODE_1_IP="$(get_ts_ip "$NODE_1_HOST")"

log "Tailscale node addresses"

echo "server : $SERVER_IP"
echo "node-0 : $NODE_0_IP"
echo "node-1 : $NODE_1_IP"

log "Enabling IPv4 forwarding on workers"

for host in "$NODE_0_HOST" "$NODE_1_HOST"; do
  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    cat > /etc/sysctl.d/99-kubernetes-tailscale.conf <<EOF
net.ipv4.ip_forward = 1
EOF

    sysctl -p /etc/sysctl.d/99-kubernetes-tailscale.conf

    if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
      echo "ERROR: IPv4 forwarding is not enabled." >&2
      exit 1
    fi
  '
done

log "Advertising Pod CIDRs through Tailscale"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}"   "tailscale set --advertise-routes='${NODE_0_SUBNET}'"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}"   "tailscale set --advertise-routes='${NODE_1_SUBNET}'"

log "Enabling route acceptance"

tailscale ssh "${SSH_USER}@${SERVER_HOST}"   "tailscale set --accept-routes=true"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}"   "tailscale set --accept-routes=true"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}"   "tailscale set --accept-routes=true"

log "Tailscale route preferences"

for host in "$SERVER_HOST" "$NODE_0_HOST" "$NODE_1_HOST"; do
  echo
  echo "[$host]"
  tailscale ssh "${SSH_USER}@${host}" "tailscale debug prefs || true"
done

log "Current Tailscale routing tables"

for host in "$SERVER_HOST" "$NODE_0_HOST" "$NODE_1_HOST"; do
  echo
  echo "[$host - table 52]"
  tailscale ssh "${SSH_USER}@${host}" "ip route show table 52 || true"
done

wait_for_route() {
  local host="$1"
  local subnet="$2"

  echo
  echo "Waiting on $host for route $subnet..."

  for attempt in {1..90}; do
    routes="$(tailscale ssh "${SSH_USER}@${host}" "ip route show table 52 || true")"

    if grep -Fq "$subnet" <<< "$routes"; then
      echo "Route $subnet is available on $host."
      return 0
    fi

    echo "Route not available yet. ($attempt/90)"

    if (( attempt % 10 == 0 )); then
      echo
      echo "Current table 52 on $host:"
      echo "$routes"
      echo
    fi

    sleep 2
  done

  echo
  echo "Route $subnet did not appear on $host."
  echo
  echo "Final Tailscale table 52:"
  tailscale ssh "${SSH_USER}@${host}" "ip route show table 52 || true"

  echo
  echo "Tailscale preferences:"
  tailscale ssh "${SSH_USER}@${host}" "tailscale debug prefs || true"

  echo
  echo "Likely cause:"
  echo "  The subnet route is advertised but has not been approved."
  echo
  echo "Expected advertised routes:"
  echo "  node-0 -> $NODE_0_SUBNET"
  echo "  node-1 -> $NODE_1_SUBNET"
  echo
  echo "For ephemeral CI nodes, configure Tailscale autoApprovers"
  echo "for these Pod CIDRs and tag:ci."

  return 1
}

log "Waiting for Tailscale Pod routes"

wait_for_route "$SERVER_HOST" "$NODE_0_SUBNET"
wait_for_route "$SERVER_HOST" "$NODE_1_SUBNET"
wait_for_route "$NODE_0_HOST" "$NODE_1_SUBNET"
wait_for_route "$NODE_1_HOST" "$NODE_0_SUBNET"

log "Final routing tables"

for host in "$SERVER_HOST" "$NODE_0_HOST" "$NODE_1_HOST"; do
  echo
  echo "[$host - main table]"
  tailscale ssh "${SSH_USER}@${host}" "ip route show || true"

  echo
  echo "[$host - Tailscale table 52]"
  tailscale ssh "${SSH_USER}@${host}" "ip route show table 52 || true"
done

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

log "Route test addresses"

echo "node-0 test Pod IP: $NODE_0_TEST_IP"
echo "node-1 test Pod IP: $NODE_1_TEST_IP"

log "Checking route decisions"

echo
echo "server -> node-0 Pod network"
tailscale ssh "${SSH_USER}@${SERVER_HOST}"   "ip route get '${NODE_0_TEST_IP}'"

echo
echo "server -> node-1 Pod network"
tailscale ssh "${SSH_USER}@${SERVER_HOST}"   "ip route get '${NODE_1_TEST_IP}'"

echo
echo "node-0 -> node-1 Pod network"
tailscale ssh "${SSH_USER}@${NODE_0_HOST}"   "ip route get '${NODE_1_TEST_IP}'"

echo
echo "node-1 -> node-0 Pod network"
tailscale ssh "${SSH_USER}@${NODE_1_HOST}"   "ip route get '${NODE_0_TEST_IP}'"

log "Checking worker IPv4 forwarding"

for host in "$NODE_0_HOST" "$NODE_1_HOST"; do
  forwarding="$(
    tailscale ssh "${SSH_USER}@${host}"       "sysctl -n net.ipv4.ip_forward"
  )"

  echo "$host IPv4 forwarding: $forwarding"

  [ "$forwarding" = "1" ] || die "IPv4 forwarding is disabled on $host"
done

log "Checking worker Pod routes"

echo
echo "[node-0]"
tailscale ssh "${SSH_USER}@${NODE_0_HOST}"   "ip route show '${NODE_0_SUBNET}' || true"

echo
echo "[node-1]"
tailscale ssh "${SSH_USER}@${NODE_1_HOST}"   "ip route show '${NODE_1_SUBNET}' || true"

log "Pod network routes configured"

echo
echo "Routing topology:"
echo
echo "node-0"
echo "  Tailscale IP : $NODE_0_IP"
echo "  Pod CIDR     : $NODE_0_SUBNET"
echo
echo "node-1"
echo "  Tailscale IP : $NODE_1_IP"
echo "  Pod CIDR     : $NODE_1_SUBNET"
echo
echo "server"
echo "  Tailscale IP : $SERVER_IP"
echo
echo "Tailscale subnet routes are installed through table 52."
echo
echo "Step 11 completed successfully."
