require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "sprockets/railtie"

Bundler.require(*Rails.groups)

module IskacameMk
  class Application < Rails::Application
    config.load_defaults 7.2
    config.autoload_lib(ignore: %w[assets tasks])
    config.api_only = false
  end
end