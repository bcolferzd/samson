# frozen_string_literal: true
module SamsonAirbrake
  class Engine < Rails::Engine
  end

  class Notification
    class << self
      VALID_RAILS_ENV = /^[a-z]+$/
      SECRET_KEY = 'airbrake_api_key'

      def deliver_for(deploy)
        return unless DeployGroup.enabled?
        return unless deploy.stage.notify_airbrake
        return unless deploy.succeeded?

        deploy.stage.deploy_groups.group_by(&:environment).each do |environment, deploy_groups|
          rails_env = environment.name.downcase
          next unless rails_env =~ VALID_RAILS_ENV

          next unless project_api_key = read_secret(deploy.project, deploy_groups, SECRET_KEY)

          # using v1 deploy api since it does not need the project_id to simplify configuration
          Faraday.post(
            "https://api.airbrake.io/deploys.txt",
            api_key: project_api_key,
            deploy: {
              rails_env: rails_env,
              scm_revision: deploy.job.commit,
              local_username: deploy.user.name
            }
          )
        end
      end

      private

      def read_secret(project, deploy_groups, key)
        Samson::Secrets::KeyResolver.new(project, deploy_groups).read(key)
      end
    end
  end
end

Samson::Hooks.callback :after_deploy do |deploy, _buddy|
  SamsonAirbrake::Notification.deliver_for(deploy)
end

Samson::Hooks.view :stage_form, 'samson_airbrake/stage_form'

Samson::Hooks.callback(:stage_permitted_params) { :notify_airbrake }
