require "base64"
require "crinja"

require "../../configuration/main"
require "../../util"
require "../../util/ssh"
require "../client"
require "../instance"
require "../network"
require "./find"
require "./find_by_id"

class Hetzner::Instance::Adopt
  include Util

  BOOTSTRAP_SCRIPT            = {{ read_file("#{__DIR__}/../../../templates/adopted_instance_bootstrap.sh") }}
  CLOUD_INIT_WAIT_SCRIPT      = {{ read_file("#{__DIR__}/../../../templates/cloud_init_wait_script.sh") }}
  SSH_CONFIGURATION_SCRIPT    = {{ read_file("#{__DIR__}/../../../templates/ssh/configure_ssh.sh") }}
  SSH_LISTEN_CONFIGURATION    = {{ read_file("#{__DIR__}/../../../templates/ssh/listen.conf") }}
  TAILSCALE_SSH_WAIT_ATTEMPTS = 60

  getter instance_name : String

  private getter settings : Configuration::Main
  private getter hetzner_client : Hetzner::Client
  private getter instance_type : String
  private getter location : String
  private getter role : String
  private getter network : Hetzner::Network?
  private getter additional_packages : Array(String)
  private getter additional_pre_k3s_commands : Array(String)
  private getter bootstrap_ssh : Util::SSH
  private getter cluster_ssh : Util::SSH
  private property resuming : Bool = false
  private property tailscale_ip : String?

  def initialize(
    @settings : Configuration::Main,
    @hetzner_client : Hetzner::Client,
    @instance_id : Int64,
    @instance_name : String,
    @instance_type : String,
    @location : String,
    @role : String,
    @network : Hetzner::Network?,
    @additional_packages : Array(String),
    @additional_pre_k3s_commands : Array(String)
  )
    ssh = settings.networking.ssh
    @bootstrap_ssh = Util::SSH.new(ssh.private_key_path, ssh.public_key_path, false)
    @cluster_ssh = Util::SSH.new(
      ssh.private_key_path,
      ssh.public_key_path,
      ssh.use_private_ip,
      tailscale_hostname_suffix: settings.networking.tailscale.ssh_hostname_suffix
    )
  end

  def preflight : Nil
    instance = find_instance
    validate_instance(instance)
    validate_name_available(instance)
    wait_for_cloud_init(instance)
    validate_clean_host(instance)
    validate_cluster_label(instance)
  end

  def run : Hetzner::Instance
    instance = find_instance
    validate_instance(instance)
    validate_name_available(instance)
    validate_clean_host(instance)
    validate_cluster_label(instance)
    mark_adoption(instance)
    instance = find_instance
    update_name(instance)
    instance = find_instance

    bootstrap_ssh.run(instance, 22, CLOUD_INIT_WAIT_SCRIPT, settings.networking.ssh.use_agent, print_output: false)
    bootstrap_ssh.run(instance, 22, bootstrap_script, settings.networking.ssh.use_agent)
    capture_tailscale_ip(instance)

    instance.tailscale_ip = tailscale_ip
    wait_for_cluster_ssh(instance)
    attach_to_network(instance)
    update_labels(find_instance)

    instance = find_instance
    instance.adopted = true
    instance.selected_network_id = network.try(&.id)
    instance.tailscale_ip = tailscale_ip
    instance
  end

  private def capture_tailscale_ip(instance) : Nil
    return unless settings.networking.tailscale.enabled

    output = bootstrap_ssh.run(
      instance,
      22,
      "tailscale ip -4 | head -n1",
      settings.networking.ssh.use_agent,
      print_output: false
    ).strip
    raise "Tailscale did not assign an IPv4 address to adopted server #{@instance_id}" if output.empty?

    self.tailscale_ip = output
  end

  private def find_instance : Hetzner::Instance
    Hetzner::Instance::FindById.new(hetzner_client, @instance_id).run
  end

  private def validate_instance(instance) : Nil
    errors = [] of String
    errors << "must be running" unless instance.status == "running"
    errors << "must have a public IPv4 address" if instance.public_ip_address.nil?
    errors << "has type '#{instance.server_type.try(&.name)}', expected '#{instance_type}'" unless instance.server_type.try(&.name) == instance_type
    errors << "is in location '#{instance.location.try(&.name)}', expected '#{location}'" unless instance.location.try(&.name) == location

    conflicting_cluster = instance.labels["cluster"]?
    if conflicting_cluster && conflicting_cluster != settings.cluster_name
      errors << "belongs to cluster '#{conflicting_cluster}' according to its labels"
    end

    adoption_cluster = instance.labels["hetzner-k3s-adoption-cluster"]?
    if adoption_cluster && adoption_cluster != settings.cluster_name
      errors << "is already being adopted by cluster '#{adoption_cluster}'"
    end

    selected_network = network
    private_interfaces = instance.private_net || [] of Hetzner::NetworkInterface
    if selected_network && private_interfaces.any? { |network_interface| network_interface.network != selected_network.id }
      errors << "is attached to a different private network; detach it before adoption"
    elsif selected_network.nil? && private_interfaces.any?
      errors << "is attached to a private network; detach it before adoption"
    end

    return if errors.empty?

    raise "Cannot adopt Hetzner server #{@instance_id}: #{errors.join("; ")}"
  end

  private def wait_for_cloud_init(instance) : Nil
    bootstrap_ssh.run(instance, 22, CLOUD_INIT_WAIT_SCRIPT, settings.networking.ssh.use_agent, print_output: false)
  rescue ex : IO::Error
    raise "Cannot adopt Hetzner server #{@instance_id}: cloud-init did not finish: #{ex.message}"
  end

  private def validate_name_available(instance) : Nil
    existing = Hetzner::Instance::Find.new(settings, hetzner_client, instance_name).run
    return unless existing && existing.id != instance.id

    raise "Cannot rename Hetzner server #{@instance_id} to '#{instance_name}': that name is already used by server #{existing.id}"
  end

  private def validate_clean_host(instance) : Nil
    marker = adoption_marker
    command = <<-BASH
      set -e
      . /etc/os-release
      [ "$ID" = "ubuntu" ] && [ "$VERSION_ID" = "24.04" ] || { echo unsupported-os; exit 1; }
      if [ -f /etc/hetzner-k3s-adoption ]; then
        [ "$(cat /etc/hetzner-k3s-adoption)" = "#{marker}" ] || { echo conflicting-adoption; exit 1; }
        echo resuming
        exit 0
      fi
      [ ! -e /etc/initialized ] || { echo initialized; exit 1; }
      [ ! -d /etc/rancher/k3s ] || { echo existing-k3s; exit 1; }
      [ ! -d /var/lib/rancher/k3s ] || { echo existing-k3s; exit 1; }
      ! systemctl is-active --quiet k3s 2>/dev/null || { echo existing-k3s; exit 1; }
      ! systemctl is-active --quiet k3s-agent 2>/dev/null || { echo existing-k3s; exit 1; }
      ! systemctl is-active --quiet tailscaled 2>/dev/null || { echo existing-tailscale; exit 1; }
      echo ready
      BASH

    output = bootstrap_ssh.run(instance, 22, command, settings.networking.ssh.use_agent, print_output: false)
    result = output.strip
    self.resuming = result == "resuming"
    raise "Cannot adopt Hetzner server #{@instance_id}: host preflight failed" unless result == "ready" || resuming
  rescue ex : IO::Error
    raise "Cannot adopt Hetzner server #{@instance_id}: #{ex.message}"
  end

  private def validate_cluster_label(instance) : Nil
    cluster_label = instance.labels["cluster"]?
    return unless cluster_label
    return if resuming && cluster_label == settings.cluster_name

    raise "Cannot adopt Hetzner server #{@instance_id}: remove its existing cluster label before adoption"
  end

  private def mark_adoption(instance) : Nil
    labels = instance.labels.merge({
      "hetzner-k3s-adopted"          => "true",
      "hetzner-k3s-adoption-cluster" => settings.cluster_name,
    })
    update_instance_labels(instance, labels, "mark adoption of")
  end

  private def update_name(instance) : Nil
    success, response = hetzner_client.put("/servers/#{instance.id}", {
      :name => instance_name,
    })
    raise "Failed to rename adopted server #{instance.id}: #{response}" unless success
  end

  private def update_labels(instance) : Nil
    labels = instance.labels.merge({
      "cluster"                      => settings.cluster_name,
      "role"                         => role,
      "hetzner-k3s-adopted"          => "true",
      "hetzner-k3s-adoption-cluster" => settings.cluster_name,
    })
    update_instance_labels(instance, labels, "update labels on")
  end

  private def update_instance_labels(instance, labels, action) : Nil
    success, response = hetzner_client.put("/servers/#{instance.id}", {
      :labels => labels,
    })
    raise "Failed to #{action} adopted server #{instance.id}: #{response}" unless success
  end

  private def attach_to_network(instance) : Nil
    selected_network = network
    return unless selected_network
    return if instance.attached_to_network?(selected_network.id)

    success, response = hetzner_client.post("/servers/#{instance.id}/actions/attach_to_network", {
      :network => selected_network.id,
    })
    raise "Failed to attach adopted server #{instance.id} to network #{selected_network.name}: #{response}" unless success

    30.times do
      current = find_instance
      return if current.attached_to_network?(selected_network.id)
      sleep 2.seconds
    end

    raise "Timed out attaching adopted server #{instance.id} to network #{selected_network.name}"
  end

  private def wait_for_cluster_ssh(instance) : Nil
    attempts = settings.networking.tailscale.enabled ? TAILSCALE_SSH_WAIT_ATTEMPTS : Util::SSH::DEFAULT_MAX_ATTEMPTS
    cluster_ssh.wait_for_instance(
      instance,
      settings.networking.ssh.port,
      settings.networking.ssh.use_agent,
      "echo ready",
      "ready",
      attempts
    )
  end

  private def bootstrap_script : String
    packages = (["fail2ban", "wireguard"] + additional_packages).uniq.join(" ")
    ssh_script = Crinja.render(SSH_CONFIGURATION_SCRIPT, {
      ssh_port: settings.networking.ssh.port,
    })
    ssh_listen_configuration = Crinja.render(SSH_LISTEN_CONFIGURATION, {
      ssh_port: settings.networking.ssh.port,
    })

    Crinja.render(BOOTSTRAP_SCRIPT, {
      adoption_marker:                 adoption_marker,
      instance_name:                   instance_name,
      packages:                        packages,
      additional_pre_k3s_commands:     additional_pre_k3s_commands.join("\n"),
      tailscale_enabled:               settings.networking.tailscale.enabled,
      tailscale_auth_key_base64:       Base64.strict_encode(settings.networking.tailscale.auth_key),
      ssh_configuration_base64:        Base64.strict_encode(ssh_script),
      ssh_listen_configuration_base64: Base64.strict_encode(ssh_listen_configuration),
    })
  end

  private def adoption_marker : String
    "#{settings.cluster_name}:#{@instance_id}"
  end

  private def default_log_prefix
    "Adopted server #{@instance_id}"
  end
end
