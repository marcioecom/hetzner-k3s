require "json"
require "./public_net"
require "./network_interface"
require "./location"
require "./instance_type"

class Hetzner::Instance
  include JSON::Serializable

  property id : Int64
  property name : String
  property status : String
  getter public_net : PublicNet?
  getter private_net : Array(Hetzner::NetworkInterface)?
  getter location : Hetzner::Location?
  getter server_type : Hetzner::InstanceType?
  property labels : Hash(String, String) = {} of String => String

  @[JSON::Field(ignore: true)]
  property adopted : Bool = false

  @[JSON::Field(ignore: true)]
  property selected_network_id : Int64?

  @[JSON::Field(ignore: true)]
  property tailscale_ip : String?

  def public_ip_address : String?
    public_net.try(&.ipv4).try(&.ip)
  end

  def public_ipv6_address : String?
    public_net.try(&.ipv6).try(&.address)
  end

  def private_ip_address : String?
    selected_network_id.try { |network_id| private_ip_address(network_id) } || private_net.try(&.first?).try(&.ip) || public_ip_address || public_ipv6_address
  end

  def private_ip_address(network_id : Int64) : String?
    private_net.try(&.find { |network_interface| network_interface.network == network_id }).try(&.ip)
  end

  def attached_to_network?(network_id : Int64) : Bool
    private_net.try(&.any? { |network_interface| network_interface.network == network_id }) || false
  end

  # The /64 the API returns, which is what the TLS SAN has to carry as a network.
  def public_ipv6_network : String?
    public_net.try(&.ipv6).try(&.ip)
  end

  # Without a preference the public address wins, IPv4 first and IPv6 next, so a cluster whose public
  # IPv4 is disabled stays reachable. The private address is only used when it is preferred or when
  # there is no public address at all.
  def host_ip_address(prefer_private_ip : Bool = false) : String?
    private_ip = selected_network_id.try { |network_id| private_ip_address(network_id) } || private_net.try(&.first?).try(&.ip)
    public_ip = public_ip_address || public_ipv6_address
    prefer_private_ip ? (private_ip || public_ip) : (public_ip || private_ip)
  end

  def master?
    /-master\d+/ =~ name
  end

  def tailscale_host(suffix : String) : String
    "#{name}.#{suffix}"
  end

  def initialize(id : Int64, status : String, instance_name : String, internal_ip : String, external_ip : String)
    @id = id
    @status = status
    @name = instance_name
    @public_net = PublicNet.new(external_ip) unless external_ip.blank?
    @private_net = [NetworkInterface.new(internal_ip)] unless internal_ip.blank?
  end
end
