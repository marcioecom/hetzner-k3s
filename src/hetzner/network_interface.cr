require "json"

class Hetzner::NetworkInterface
  include JSON::Serializable

  property network : Int64?
  property ip : String?

  def initialize(ip : String, network : Int64? = nil)
    @ip = ip
    @network = network
  end
end
