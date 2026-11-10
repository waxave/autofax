# frozen_string_literal: true

require_relative "autofax/version"
require_relative "autofax/errors"
require_relative "autofax/model"
require_relative "autofax/models"
require_relative "autofax/parsers"
require_relative "autofax/cache_store"
require_relative "autofax/base_client"
require_relative "autofax/client"
require_relative "autofax/vehicle"
require_relative "autofax/cli"

# Autofax — a Ruby API client for AutoFactsDB.com automotive parts fitment.
#
# Mirrors the Punkauto public API and CLI so the two gems are drop-in
# compatible for the shared vehicle-catalog surface.
module Autofax
  Client.prepend(PersistentClientCache)

  # Compatibility alias for the main client class.
  AutoFactsDBClient = Client unless const_defined?(:AutoFactsDBClient)
end
