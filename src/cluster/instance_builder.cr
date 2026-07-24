require "../hetzner/instance/create"
require "../hetzner/instance/adopt"
require "../hetzner/instance/provisioner"
require "./placement_group_manager"

class Cluster::InstanceBuilder
  private getter settings : Configuration::Main
  private getter hetzner_client : Hetzner::Client
  private getter mutex : Mutex
  private getter ssh_key : Hetzner::SSHKey?
  private getter network : Hetzner::Network?
  private getter placement_groups : Cluster::PlacementGroupManager::PlacementGroups

  def initialize(@settings, @hetzner_client, @mutex, @ssh_key, @network, @placement_groups)
  end

  def build_instance_name(instance_type, index, include_instance_type, prefix = "master") : String
    instance_type_part = include_instance_type ? "#{instance_type}-" : ""
    "#{settings.cluster_name}-#{instance_type_part}#{prefix}#{index + 1}"
  end

  def create_master_instance(index : Int32, location : String) : InstanceProvisioner
    masters_pool = settings.masters_pool
    legacy_instance_type = masters_pool.legacy_instance_type
    instance_type = masters_pool.instance_type

    legacy_instance_name = build_instance_name(legacy_instance_type, index, true)
    instance_name = build_instance_name(instance_type, index, settings.include_instance_type_in_instance_name)

    image = masters_pool.image || settings.image
    additional_packages = masters_pool.additional_packages || settings.additional_packages
    additional_pre_k3s_commands = masters_pool.additional_pre_k3s_commands || settings.additional_pre_k3s_commands
    additional_post_k3s_commands = masters_pool.additional_post_k3s_commands || settings.additional_post_k3s_commands
    grow_root_partition_automatically = masters_pool.effective_grow_root_partition_automatically(settings.grow_root_partition_automatically)
    placement_group = master_placement_group(index)

    if existing_server_id = masters_pool.existing_server_ids[index]?
      return Hetzner::Instance::Adopt.new(
        settings: settings,
        hetzner_client: hetzner_client,
        instance_id: existing_server_id,
        instance_name: instance_name,
        instance_type: instance_type,
        location: location,
        role: "master",
        network: network,
        additional_packages: additional_packages,
        additional_pre_k3s_commands: additional_pre_k3s_commands
      )
    end

    Hetzner::Instance::Create.new(
      settings: settings,
      hetzner_client: hetzner_client,
      mutex: mutex,
      legacy_instance_name: legacy_instance_name,
      instance_name: instance_name,
      instance_type: instance_type,
      image: image,
      ssh_key: ssh_key.not_nil!,
      network: network,
      additional_packages: additional_packages,
      additional_pre_k3s_commands: additional_pre_k3s_commands,
      additional_post_k3s_commands: additional_post_k3s_commands,
      location: location,
      grow_root_partition_automatically: grow_root_partition_automatically,
      placement_group: placement_group
    )
  end

  def create_worker_instance(index : Int32, node_pool) : InstanceProvisioner
    legacy_instance_type = node_pool.legacy_instance_type
    instance_type = node_pool.instance_type

    legacy_instance_name = build_instance_name(legacy_instance_type, index, true, "pool-#{node_pool.name}-worker")
    instance_name = build_instance_name(instance_type, index, settings.include_instance_type_in_instance_name, "pool-#{node_pool.name}-worker")

    image = node_pool.image || settings.image
    additional_packages = node_pool.additional_packages || settings.additional_packages
    additional_pre_k3s_commands = node_pool.additional_pre_k3s_commands || settings.additional_pre_k3s_commands
    additional_post_k3s_commands = node_pool.additional_post_k3s_commands || settings.additional_post_k3s_commands
    grow_root_partition_automatically = node_pool.effective_grow_root_partition_automatically(settings.grow_root_partition_automatically)
    placement_group = worker_placement_group(index, node_pool)

    if existing_server_id = node_pool.existing_server_ids[index]?
      return Hetzner::Instance::Adopt.new(
        settings: settings,
        hetzner_client: hetzner_client,
        instance_id: existing_server_id,
        instance_name: instance_name,
        instance_type: instance_type,
        location: node_pool.location || default_masters_location,
        role: "worker",
        network: network,
        additional_packages: additional_packages,
        additional_pre_k3s_commands: additional_pre_k3s_commands
      )
    end

    Hetzner::Instance::Create.new(
      settings: settings,
      hetzner_client: hetzner_client,
      mutex: mutex,
      legacy_instance_name: legacy_instance_name,
      instance_name: instance_name,
      instance_type: instance_type,
      image: image,
      location: node_pool.location || default_masters_location,
      ssh_key: ssh_key.not_nil!,
      network: network,
      additional_packages: additional_packages,
      additional_pre_k3s_commands: additional_pre_k3s_commands,
      additional_post_k3s_commands: additional_post_k3s_commands,
      grow_root_partition_automatically: grow_root_partition_automatically,
      placement_group: placement_group
    )
  end

  def initialize_master_instances(masters_locations) : Array(InstanceProvisioner)
    Array(InstanceProvisioner).new(settings.masters_pool.instance_count) do |i|
      create_master_instance(i, masters_locations[i])
    end
  end

  def initialize_worker_instances : Array(InstanceProvisioner)
    factories = Array(InstanceProvisioner).new
    static_worker_node_pools = settings.worker_node_pools.reject(&.autoscaling_enabled)

    static_worker_node_pools.each do |node_pool|
      node_pool.instance_count.times do |i|
        factories << create_worker_instance(i, node_pool)
      end
    end

    factories
  end

  private def master_placement_group(index : Int32) : Hetzner::PlacementGroup?
    group_index = index // PlacementGroupManager::MAX_SERVERS_PER_PLACEMENT_GROUP
    masters = placement_groups.masters
    group_index < masters.size ? masters[group_index] : nil
  end

  private def worker_placement_group(index : Int32, node_pool) : Hetzner::PlacementGroup?
    group_index = index // PlacementGroupManager::MAX_SERVERS_PER_PLACEMENT_GROUP
    pool_name = node_pool.name || "default"
    pool_groups = placement_groups.workers[pool_name]?
    return nil unless pool_groups
    group_index < pool_groups.size ? pool_groups[group_index] : nil
  end

  private def default_masters_location
    settings.masters_pool.locations.first
  end
end
