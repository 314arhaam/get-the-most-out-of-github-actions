#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="kubernetes-the-hard-way"

: "${SERVER_IP:?SERVER_IP is required}"
: "${NODE_0_IP:?NODE_0_IP is required}"
: "${NODE_1_IP:?NODE_1_IP is required}"

SSH_USER="${SSH_USER:-root}"

log() {
  echo
  echo "==> $*"
}


# ------------------------------------------------------------
# SSH options
#
# Tailscale provides the private network.
# Disable interactive host-key confirmation because this runs
# inside an automated GitHub Actions environment.
# ------------------------------------------------------------

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

SCP_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
)


# ------------------------------------------------------------
# Locate cloned Kubernetes The Hard Way repository
# ------------------------------------------------------------

if [ ! -d "$REPO_DIR" ]; then
  echo "ERROR: $REPO_DIR does not exist."
  echo "The previous jumpbox step must clone the repository first."
  exit 1
fi

cd "$REPO_DIR"

log "Working inside repository"

pwd


# ------------------------------------------------------------
# Create machines.txt
#
# Format:
#
# IPV4_ADDRESS FQDN HOSTNAME POD_SUBNET
# ------------------------------------------------------------

log "Creating machines.txt using Tailscale IP addresses"

cat > machines.txt <<EOF
${SERVER_IP} server.kubernetes.local server
${NODE_0_IP} node-0.kubernetes.local node-0 10.200.0.0/24
${NODE_1_IP} node-1.kubernetes.local node-1 10.200.1.0/24
EOF

cat machines.txt


# ------------------------------------------------------------
# Wait until every Tailscale node responds
# ------------------------------------------------------------

log "Waiting for Tailscale nodes"

while read -r IP FQDN HOST SUBNET; do

  echo "Checking ${HOST} (${IP})..."

  ready=false

  for attempt in {1..60}; do

    if tailscale ping --timeout=2s "$IP" >/dev/null 2>&1; then
      ready=true
      break
    fi

    echo "Waiting for ${HOST}... (${attempt}/60)"
    sleep 2

  done

  if [ "$ready" != true ]; then
    echo "ERROR: ${HOST} (${IP}) is not reachable through Tailscale."
    exit 1
  fi

done < machines.txt


# ------------------------------------------------------------
# Verify SSH access
#
# No ssh-copy-id is needed when Tailscale SSH is being used.
# ------------------------------------------------------------

log "Verifying SSH access"

while read -r IP FQDN HOST SUBNET; do

  echo "Connecting to ${HOST} (${IP})..."

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${IP}" \
    hostname

done < machines.txt


# ------------------------------------------------------------
# Configure hostnames
# ------------------------------------------------------------

log "Configuring Kubernetes node hostnames"

while read -r IP FQDN HOST SUBNET; do

  echo "Configuring hostname on ${IP}: ${HOST}"

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${IP}" \
    "
      set -euo pipefail

      sudo sed -i \
        's/^127\.0\.1\.1.*/127.0.1.1\t${FQDN} ${HOST}/' \
        /etc/hosts

      sudo hostnamectl set-hostname '${HOST}'

      sudo systemctl restart systemd-hostnamed
    "

done < machines.txt


# ------------------------------------------------------------
# Verify FQDNs
# ------------------------------------------------------------

log "Verifying hostnames"

while read -r IP FQDN HOST SUBNET; do

  echo -n "${HOST}: "

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${IP}" \
    hostname --fqdn

done < machines.txt


# ------------------------------------------------------------
# Generate hosts file
# ------------------------------------------------------------

log "Generating Kubernetes hosts file"

cat > hosts <<'EOF'

# Kubernetes The Hard Way
EOF

while read -r IP FQDN HOST SUBNET; do

  echo "${IP} ${FQDN} ${HOST}" >> hosts

done < machines.txt

cat hosts


# ------------------------------------------------------------
# Add Kubernetes hosts to jumpbox
#
# Remove old KTHW block first so rerunning the script doesn't
# continually duplicate entries.
# ------------------------------------------------------------

log "Updating jumpbox /etc/hosts"

sudo sed -i \
  '/# Kubernetes The Hard Way/,/# End Kubernetes The Hard Way/d' \
  /etc/hosts

{
  echo
  echo "# Kubernetes The Hard Way"

  while read -r IP FQDN HOST SUBNET; do
    echo "${IP} ${FQDN} ${HOST}"
  done < machines.txt

  echo "# End Kubernetes The Hard Way"
} | sudo tee -a /etc/hosts >/dev/null


# ------------------------------------------------------------
# Verify hostname lookup from jumpbox
# ------------------------------------------------------------

log "Testing hostname resolution"

for host in server node-0 node-1; do

  echo "Resolving ${host}..."

  getent hosts "$host"

done


# ------------------------------------------------------------
# Copy host entries to every remote machine
# ------------------------------------------------------------

log "Distributing hosts file"

while read -r IP FQDN HOST SUBNET; do

  echo "Updating /etc/hosts on ${HOST}"

  scp \
    "${SCP_OPTS[@]}" \
    hosts \
    "${SSH_USER}@${IP}:/tmp/kubernetes-hosts"

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${IP}" \
    "
      set -euo pipefail

      sudo sed -i \
        '/# Kubernetes The Hard Way/,/# End Kubernetes The Hard Way/d' \
        /etc/hosts

      {
        echo
        echo '# Kubernetes The Hard Way'
        cat /tmp/kubernetes-hosts |
          sed '/^# Kubernetes The Hard Way/d'
        echo '# End Kubernetes The Hard Way'
      } | sudo tee -a /etc/hosts >/dev/null

      rm -f /tmp/kubernetes-hosts
    "

done < machines.txt


# ------------------------------------------------------------
# Final SSH verification using Kubernetes hostnames
# ------------------------------------------------------------

log "Testing SSH using configured hostnames"

for host in server node-0 node-1; do

  echo -n "${host}: "

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${host}" \
    hostname

done


# ------------------------------------------------------------
# Final verification from every Kubernetes machine
# ------------------------------------------------------------

log "Testing cross-node hostname resolution"

while read -r IP FQDN HOST SUBNET; do

  echo
  echo "Checking from ${HOST}:"

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${IP}" \
    "
      set -euo pipefail

      getent hosts server
      getent hosts node-0
      getent hosts node-1
    "

done < machines.txt


log "Compute-resource configuration completed"

echo
echo "machines.txt:"
cat machines.txt

echo
echo "hosts:"
cat hosts

echo
echo "All Kubernetes machines are reachable over Tailscale."