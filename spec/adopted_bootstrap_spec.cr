require "./routing_spec_helper"
require "../src/hetzner/instance/adopt"

private class AdoptProbe < Hetzner::Instance::Adopt
  def rendered_bootstrap : String
    bootstrap_script
  end
end

private def adopt_config(tailscale = true) : String
  <<-YAML
  config_format_version: 1
  hetzner_token: ""
  cluster_name: routing-test
  kubeconfig_path: /nonexistent/kubeconfig
  k3s_version: v1.35.0+k3s1
  networking:
    private_network:
      enabled: true
    tailscale:
      enabled: #{tailscale}
      hostname_suffix: tail1234ab.ts.net
      auth_key: tskey-auth-kExampleKey
      version: "1.80.2"
    cni:
      enabled: true
      mode: cilium
  masters_pool:
    instance_type: cpx22
    instance_count: 1
  worker_node_pools: []
  YAML
end

private def adopt_probe(tailscale = true) : AdoptProbe
  AdoptProbe.new(
    Configuration::Main.from_yaml(adopt_config(tailscale)),
    Hetzner::Client.new(""),
    1_i64,
    "routing-test-worker1",
    "cpx22",
    "nbg1",
    "worker",
    nil,
    [] of String,
    [] of String
  )
end

# The script embeds the Tailscale installer as base64, so the assertions have to read it back.
private def embedded_installer(script : String) : String
  line = script.lines.find! { |candidate| candidate.includes?("base64 -d") && candidate.includes?("install-tailscale.sh") }
  # The line quotes the format string first and the payload second.
  blob = line.scan(/'([^']+)'/).map(&.[1]).max_by(&.size)
  String.new(Base64.decode(blob))
end

describe "adopted server bootstrap" do
  it "joins the tailnet with the same flags as the cloud-init path" do
    script = adopt_probe.rendered_bootstrap

    script.should contain("--accept-dns=false")
    script.should_not contain("--accept-routes")
    script.should_not contain("tailscale set --accept-dns=false")
  end

  it "installs Tailscale from the signed repository and keeps the pinned version" do
    script = adopt_probe.rendered_bootstrap
    installer = embedded_installer(script)

    script.should_not contain("tailscale.com/install.sh")
    installer.should contain("pkgs.tailscale.com")
    installer.should contain(%(TAILSCALE_VERSION="1.80.2"))
  end

  it "leaves the script free of the tailnet when Tailscale is disabled" do
    script = adopt_probe(tailscale: false).rendered_bootstrap

    script.should_not contain("tailscale")
  end
end
