require "./create"
require "./adopt"

alias InstanceProvisioner = Hetzner::Instance::Create | Hetzner::Instance::Adopt
