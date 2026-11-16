require "./routing_spec_helper"

private def pool_errors(yaml : String) : String
  pool = Configuration::Models::WorkerNodePool.from_yaml(yaml)
  errors = [] of String

  Configuration::Validators::NodePool.new(
    errors: errors,
    pool: pool,
    pool_type: :workers,
    masters_pool: Configuration::Models::MasterNodePool.from_yaml({"instance_type" => "cpx22", "instance_count" => 1}.to_yaml),
    instance_types: [Hetzner::InstanceType.from_json({"id" => 1, "name" => "cpx22"}.to_json)],
    all_locations: [Hetzner::Location.from_json({"id" => 1, "name" => "nbg1", "network_zone" => "eu-central"}.to_json)],
    datastore: Configuration::Models::Datastore.from_yaml({"mode" => "etcd"}.to_yaml),
    private_network_enabled: true
  ).validate

  errors.join("\n")
end

private def pool_with(yaml : String) : String
  pool_errors("instance_type: cpx22\n" + yaml)
end

describe "existing_server_ids validation" do
  it "accepts one id per instance" do
    pool_with(<<-YAML).should_not contain("existing_server_id")
      name: adopted
      instance_count: 2
      location: nbg1
      existing_server_ids:
      - 101
      - 102
      YAML
  end

  it "requires one id per instance" do
    pool_with(<<-YAML).should contain("expected 3, got 2")
      name: adopted
      instance_count: 3
      existing_server_ids:
      - 101
      - 102
      YAML
  end

  it "rejects ids that cannot exist" do
    pool_with(<<-YAML).should contain("IDs must be positive")
      name: adopted
      instance_count: 1
      existing_server_ids:
      - 0
      YAML
  end

  it "rejects a pool that combines ids with external nodes" do
    pool_with(<<-YAML).should contain("cannot combine existing_server_ids with external nodes")
      name: adopted
      instance_type: external
      instance_count: 1
      existing_server_ids:
      - 101
      external:
        provider: generic
        nodes:
        - host: 10.10.0.90
          ssh_user: operator
          ssh_port: 2222
          ssh_private_key_path: /nonexistent/test-key
          manage_hostname: true
          index: 1
      YAML
  end

  it "rejects a pool that combines ids with autoscaling" do
    pool_with(<<-YAML).should contain("cannot combine existing_server_ids with autoscaling")
      name: adopted
      instance_count: 1
      existing_server_ids:
      - 101
      autoscaling:
        enabled: true
        min_instances: 0
        max_instances: 3
      YAML
  end
end
