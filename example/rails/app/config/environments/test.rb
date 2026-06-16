require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.cache_classes = true
  config.enable_reloading = false
  config.eager_load = true
  config.public_file_server.enabled = true
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.cache_store = :null_store
  config.active_support.deprecation = :stderr
  config.active_support.disallowed_deprecation = :raise
  config.active_support.disallowed_deprecation_warnings = []
  config.active_record.maintain_test_schema = false
  config.secret_key_base = "sporevm-rails-example-test-secret"
end
