require "../client"
require "../instance_response"

class Hetzner::Instance::FindById
  def initialize(@hetzner_client : Hetzner::Client, @instance_id : Int64)
  end

  def run : Hetzner::Instance
    success, response = @hetzner_client.get("/servers/#{@instance_id}")
    raise "Unable to find Hetzner server #{@instance_id}: #{response}" unless success

    instance = Hetzner::InstanceResponse.from_json(response).server
    raise "Hetzner API returned server #{instance.id} while looking up #{@instance_id}" unless instance.id == @instance_id

    instance
  end
end
