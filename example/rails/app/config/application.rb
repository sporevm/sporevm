require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

module SporevmRailsExample
  class Application < Rails::Application
    config.load_defaults 7.2
    config.api_only = true
    config.eager_load = true

    runtime_root = ENV.fetch("SPOREVM_RAILS_RUNTIME_ROOT", "/tmp/sporevm-rails")
    config.paths["tmp"] = File.join(runtime_root, "tmp")
    config.cache_store = :file_store, File.join(runtime_root, "cache")
  end
end
