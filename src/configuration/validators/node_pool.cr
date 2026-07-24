require "../../hetzner/location"
require "../../hetzner/instance_type"
require "../models/node_pool"
require "./datastore"

class Configuration::Validators::NodePool
  getter errors : Array(String) = [] of String
  getter pool : Configuration::Models::MasterNodePool | Configuration::Models::WorkerNodePool
  getter pool_type : Symbol = :workers
  getter masters_pool : Configuration::Models::MasterNodePool
  getter instance_types : Array(Hetzner::InstanceType) = [] of Hetzner::InstanceType
  getter all_locations : Array(Hetzner::Location) = [] of Hetzner::Location

  getter pool_name : String { masters? ? "masters" : pool.try(&.name) || "<unnamed-pool>" }
  getter pool_description : String { workers? ? "Worker mode pool '#{pool_name}'" : "Masters pool" }

  getter datastore : Configuration::Models::Datastore
  getter private_network_enabled : Bool = true

  def initialize(@errors, @pool, @pool_type, @masters_pool, @instance_types, @all_locations, @datastore, @private_network_enabled = true)
  end

  def validate
    return unless pool

    validate_existing_server_ids

    Configuration::Validators::NodePoolConfig::PoolName.new(errors, pool_type, pool_name).validate
    Configuration::Validators::NodePoolConfig::InstanceType.new(errors, pool, instance_types).validate

    unless pool.try(&.external?)
      Configuration::Validators::NodePoolConfig::Location.new(errors, pool, pool_type, masters_pool, all_locations, private_network_enabled, datastore.mode).validate
      Configuration::Validators::NodePoolConfig::InstanceCount.new(errors, pool, pool_type, datastore).validate unless pool.autoscaling_enabled
    end

    Configuration::Validators::NodePoolConfig::Labels.new(errors, pool_type, pool.try(&.labels)).validate
    Configuration::Validators::NodePoolConfig::Taints.new(errors, pool_type, pool.try(&.taints)).validate
    Configuration::Validators::NodePoolConfig::Autoscaling.new(errors, pool).validate if workers? && !pool.try(&.external?)
  end

  private def workers?
    pool_type == :workers
  end

  private def masters?
    pool_type == :masters
  end

  private def validate_existing_server_ids
    ids = pool.existing_server_ids
    return if ids.empty?

    errors << "#{pool_description} must have one existing_server_id per instance (expected #{pool.instance_count}, got #{ids.size})" if ids.size != pool.instance_count
    errors << "#{pool_description} has invalid existing_server_ids; IDs must be positive" if ids.any? { |id| id <= 0 }
    errors << "#{pool_description} has duplicate existing_server_ids" if ids.uniq.size != ids.size
    errors << "#{pool_description} cannot combine existing_server_ids with external nodes" if pool.external?
    errors << "#{pool_description} cannot combine existing_server_ids with autoscaling" if pool.autoscaling_enabled
  end
end
