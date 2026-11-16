require "./instance"

class Hetzner::InstanceResponse
  include JSON::Serializable

  property server : Hetzner::Instance
end
