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
apt-get update -qq
apt-get install -y -qq {{ packages }}

printf 'nameserver 8.8.8.8\n' > /etc/k8s-resolv.conf

{{ additional_pre_k3s_commands }}

{% if tailscale_enabled %}
trap 'rm -f /run/tailscale-authkey' EXIT
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if tailscale ip -4 >/dev/null 2>&1; then
  tailscale set --hostname='{{ instance_name }}' --accept-routes
else
  printf '%s' '{{ tailscale_auth_key_base64 }}' | base64 -d > /run/tailscale-authkey
  chmod 0600 /run/tailscale-authkey
  tailscale up --authkey="$(cat /run/tailscale-authkey)" --hostname='{{ instance_name }}' --accept-routes
  rm -f /run/tailscale-authkey
fi
trap - EXIT
tailscale set --accept-dns=false
{% endif %}

printf '%s' '{{ ssh_configuration_base64 }}' | base64 -d > /etc/configure_ssh.sh
chmod 0755 /etc/configure_ssh.sh
mkdir -p /etc/systemd/system/ssh.socket.d
printf '%s' '{{ ssh_listen_configuration_base64 }}' | base64 -d > /etc/systemd/system/ssh.socket.d/listen.conf
/etc/configure_ssh.sh

touch "$BOOTSTRAP_MARKER"
