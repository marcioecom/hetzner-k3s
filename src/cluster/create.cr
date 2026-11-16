require "../configuration/loader"
require "../hetzner/ssh_key/create"
require "../kubernetes/installer"
require "../util/ssh"
require "./external_node_validator"
require "./firewall_manager"
require "./instance_builder"
require "./load_balancer_manager"
require "./network_manager"
require "./node_pool_reconciler"
require "./placement_group_manager"

class Cluster::Create
  private getter configuration : Configuration::Loader
  private getter hetzner_client : Hetzner::Client { configuration.hetzner_client }
  private getter settings : Configuration::Main { configuration.settings }
  private getter autoscaling_worker_node_pools : Array(Configuration::Models::WorkerNodePool) { settings.worker_node_pools.select(&.autoscaling_enabled) }
  private getter ssh_client : Util::SSH do
    Util::SSH.new(
      settings.networking.ssh.private_key_path,
      settings.networking.ssh.public_key_path,
      settings.networking.ssh.use_private_ip,
      tailscale_hostname_suffix: settings.networking.tailscale.ssh_hostname_suffix
    )
  end
  private getter network : Hetzner::Network?
  private getter ssh_key : Hetzner::SSHKey
  private getter load_balancer : Hetzner::LoadBalancer?
  private getter instances : Array(Hetzner::Instance) = [] of Hetzner::Instance
  private getter master_instances : Array(InstanceProvisioner)
  private getter worker_instances : Array(InstanceProvisioner)

  private property kubernetes_masters_installation_queue_channel do
    # One slot per master. All masters are queued before the installer fiber exists, so a fixed
    # capacity smaller than the master count would block the last send forever.
    Channel(Hetzner::Instance).new(settings.masters_pool.instance_count)
  end
  private property kubernetes_workers_installation_queue_channel do
    Channel(Hetzner::Instance).new(10)
  end
  private property completed_channel : Channel(Exception?) = Channel(Exception?).new
  private property mutex : Mutex = Mutex.new

  private getter instance_builder : InstanceBuilder
  private getter network_manager : NetworkManager
  private getter load_balancer_manager : LoadBalancerManager
  private getter firewall_manager : FirewallManager
  private getter placement_group_manager : PlacementGroupManager
  private getter placement_groups : PlacementGroupManager::PlacementGroups

  def initialize(@configuration, @force : Bool = false, @dry_run : Bool = false)
    validate_external_nodes

    @network_manager = NetworkManager.new(settings, hetzner_client)
    @load_balancer_manager = LoadBalancerManager.new(settings, hetzner_client)
    @firewall_manager = FirewallManager.new(settings, hetzner_client)
    @placement_group_manager = PlacementGroupManager.new(settings, hetzner_client)

    preflight_adopted_instances

    @network = network_manager.find_or_create if settings.networking.private_network.enabled
    @ssh_key = create_ssh_key
    static_worker_node_pools = settings.worker_node_pools.reject(&.autoscaling_enabled).reject(&.external?)
    created_master_count = settings.masters_pool.adopted? ? 0 : settings.masters_pool.instance_count
    created_worker_node_pools = static_worker_node_pools.reject(&.adopted?)
    @placement_groups = placement_group_manager.create(created_master_count, created_worker_node_pools)
    @instance_builder = InstanceBuilder.new(settings, hetzner_client, mutex, ssh_key, network, placement_groups)

    @master_instances = instance_builder.initialize_master_instances(masters_locations)
    @worker_instances = create_worker_instances(static_worker_node_pools)
  end

  def run
    create_instances_concurrently(master_instances, kubernetes_masters_installation_queue_channel)

    @load_balancer = load_balancer_manager.handle(master_instances.size, network)

    firewall_manager.handle(master_created_instances)

    initiate_k3s_setup

    create_instances_concurrently(worker_instances, kubernetes_workers_installation_queue_channel)

    result = completed_channel.receive
    if result
      puts "Error during k3s setup: #{result.message}".colorize(:red)
      exit 1
    end

    reconcile_node_pools

    warn_if_not_protected
  end

  # Only ever removes workers: the expected set contains every rendered name, masters included, so a
  # master is spared, and autoscaled nodes are excluded by the reconciler itself.
  private def reconcile_node_pools
    return unless settings.reconcile_node_pools

    documented_names = (master_instances + worker_instances).map(&.instance_name)

    reconciler = Cluster::NodePoolReconciler.new(configuration, @force, @dry_run)
    return if reconciler.run(documented_names)

    puts
    reconciler.errors.each { |error| puts "Failed to remove #{error}".colorize(:red) }
    puts "Re-run create once the nodes above can be drained.".colorize(:yellow)
    exit 1
  end

  private def validate_external_nodes
    Cluster::ExternalNodeValidator.new(settings).validate
  end

  private def create_ssh_key
    Hetzner::SSHKey::Create.new(hetzner_client, settings).run
  end

  private def warn_if_not_protected
    return if settings.protect_against_deletion

    puts
    puts "WARNING!!! The cluster is not protected against deletion. If you want to protect the cluster against deletion, set `protect_against_deletion: true` in the configuration file.".colorize(:yellow)
    puts
  end

  private def initiate_k3s_setup
    kubernetes_installer = Kubernetes::Installer.new(
      configuration,
      load_balancer,
      ssh_client,
      autoscaling_worker_node_pools
    )

    spawn do
      begin
        kubernetes_installer.run(
          masters_installation_queue_channel: kubernetes_masters_installation_queue_channel,
          workers_installation_queue_channel: kubernetes_workers_installation_queue_channel,
          completed_channel: completed_channel,
          master_count: master_instances.size,
          worker_count: worker_instances.size
        )
        completed_channel.send(nil)
      rescue ex : Exception
        completed_channel.send(ex)
      end
    end
  end

  # ## Instances

  private def masters_locations : Array(String)
    settings.masters_pool.locations
  end

  private def create_worker_instances(node_pools) : Array(InstanceProvisioner)
    factories = Array(InstanceProvisioner).new

    node_pools.each do |node_pool|
      node_pool.instance_count.times do |i|
        factories << instance_builder.create_worker_instance(i, node_pool)
      end
    end

    factories
  end

  private def preflight_adopted_instances : Nil
    return unless settings.adopted_servers?

    preflight_network = nil
    if settings.networking.private_network.enabled
      configured_name = settings.networking.private_network.existing_network_name
      network_name = configured_name.empty? ? settings.cluster_name : configured_name
      preflight_network = network_manager.find_existing(network_name)
    end

    builder = InstanceBuilder.new(
      settings,
      hetzner_client,
      mutex,
      nil,
      preflight_network,
      PlacementGroupManager::PlacementGroups.new
    )

    if settings.masters_pool.adopted?
      settings.masters_pool.instance_count.times do |index|
        builder.create_master_instance(index, masters_locations[index]).as(Hetzner::Instance::Adopt).preflight
      end
    end

    settings.worker_node_pools.select(&.adopted?).each do |node_pool|
      node_pool.instance_count.times do |index|
        builder.create_worker_instance(index, node_pool).as(Hetzner::Instance::Adopt).preflight
      end
    end
  end

  private def handle_created_instance(created_instance, kubernetes_installation_queue_channel)
    instances << created_instance
    kubernetes_installation_queue_channel.send(created_instance)
  end

  # Waits for every factory and fails the whole create on the first error. The channel is sized to
  # the number of factories so a failing fiber never blocks when it reports, which would also skip
  # the `ensure` that returns the semaphore slot.
  private def create_instances_concurrently(instance_factories, kubernetes_installation_queue_channel) : Nil
    results = Channel(Exception?).new(instance_factories.size)
    semaphore = Channel(Nil).new(10)

    instance_factories.each do |instance_factory|
      semaphore.send(nil)
      spawn do
        begin
          handle_created_instance(instance_factory.run, kubernetes_installation_queue_channel)
          results.send(nil)
        rescue e : Exception
          results.send(e)
        ensure
          semaphore.receive
        end
      end
    end

    errors = instance_factories.size.times.compact_map { results.receive }
    return if errors.empty?

    puts "Error creating instances: #{errors.first.message}".colorize(:red)
    exit 1
  end

  private def master_created_instances : Array(Hetzner::Instance)
    instances.select { |instance| master_instances.any? { |factory| factory.instance_name == instance.name } }
  end
end
