#!/bin/bash
set -euo pipefail

MARKER=/etc/hetzner-k3s-adoption
BOOTSTRAP_MARKER=/etc/hetzner-k3s-adoption-bootstrap

mkdir -p /etc
printf '%s\n' '{{ adoption_marker }}' > "$MARKER"

if [ -f "$BOOTSTRAP_MARKER" ]; then
  exit 0
fi

hostnamectl set-hostname '{{ instance_name }}'

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=300 update -qq
apt-get install -y -qq -o DPkg::Lock::Timeout=300 {{ packages }}

printf 'nameserver 8.8.8.8\n' > /etc/k8s-resolv.conf

{{ additional_pre_k3s_commands }}

{% if tailscale_enabled %}
printf '%s' '{{ tailscale_install_script_base64 }}' | base64 -d > /usr/local/bin/install-tailscale.sh
chmod 0755 /usr/local/bin/install-tailscale.sh

if ! command -v tailscale >/dev/null 2>&1; then
  /usr/local/bin/install-tailscale.sh
fi

# Same join command as the cloud-init path. Subnet routes are not accepted and DNS is disabled in
# the same call, so tailscaled never rewrites /etc/resolv.conf between two commands.
if tailscale ip -4 >/dev/null 2>&1; then
  tailscale set --hostname='{{ instance_name }}' --accept-dns=false
else
  trap 'rm -f /run/tailscale-authkey' EXIT
  printf '%s' '{{ tailscale_auth_key_base64 }}' | base64 -d > /run/tailscale-authkey
  chmod 0600 /run/tailscale-authkey
  tailscale up --authkey="$(cat /run/tailscale-authkey)" --hostname='{{ instance_name }}' --accept-dns=false
  rm -f /run/tailscale-authkey
  trap - EXIT
fi
{% endif %}

printf '%s' '{{ ssh_configuration_base64 }}' | base64 -d > /etc/configure_ssh.sh
chmod 0755 /etc/configure_ssh.sh
mkdir -p /etc/systemd/system/ssh.socket.d
printf '%s' '{{ ssh_listen_configuration_base64 }}' | base64 -d > /etc/systemd/system/ssh.socket.d/listen.conf
/etc/configure_ssh.sh

touch "$BOOTSTRAP_MARKER"
