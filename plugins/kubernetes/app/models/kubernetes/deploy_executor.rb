# frozen_string_literal: true
# executes a deploy and writes log to job output
# finishes when cluster is "Ready"
module Kubernetes
  class DeployExecutor
    WAIT_FOR_LIVE = ENV.fetch('KUBE_WAIT_FOR_LIVE', 10).to_i.minutes
    CHECK_STABLE = 1.minute
    TICK = 2.seconds
    RESTARTED = "Restarted"

    # TODO: this logic might be able to go directly into Pod, which would simplify the code here a bit
    ReleaseStatus = Struct.new(:live, :failed, :details, :role, :group, :pod)

    def initialize(output, job:, reference:)
      @output = output
      @job = job
      @reference = reference
    end

    def pid
      "Kubernetes-deploy-#{object_id}"
    end

    def stop!(_signal)
      @stopped = true
    end

    def execute!(*_commands)
      verify_kubernetes_templates!
      build = find_or_create_build
      return false if stopped?
      release = create_release(build)

      jobs, deploys = release.release_docs.partition(&:job?)
      if jobs.any?
        @output.puts "First deploying jobs ..." if deploys.any?
        return false unless deploy_to_cluster(release, jobs)
        @output.puts "Now deploying other roles ..." if deploys.any?
      end
      if deploys.any?
        ensure_service(deploys)
        return false unless deploy_to_cluster(release, deploys)
      end
      true
    end

    private

    def wait_for_resources_to_complete(release, release_docs)
      @wait_start_time = Time.now
      stable_ticks = CHECK_STABLE / TICK
      @output.puts "Waiting for pods to be created"

      loop do
        return false if stopped?

        statuses = pod_statuses(release, release_docs)

        if @testing_for_stability
          if statuses.all?(&:live)
            @testing_for_stability += 1
            @output.puts "Stable #{@testing_for_stability}/#{stable_ticks}"
            return success if stable_ticks == @testing_for_stability
          else
            print_statuses(statuses)
            unstable!
            return false
          end
        else
          print_statuses(statuses)
          if statuses.all?(&:live)
            if release_docs.all?(&:job?)
              return success
            else
              @output.puts "READY, starting stability test"
              @testing_for_stability = 0
            end
          elsif statuses.any?(&:failed)
            unstable!
            return false
          elsif seconds_waiting > WAIT_FOR_LIVE
            @output.puts "TIMEOUT, pods took too long to get live"
            return false
          end
        end

        sleep TICK
      end
    end

    def pod_statuses(release, release_docs)
      pods = fetch_pods(release)
      release_docs.flat_map { |release_doc| release_statuses(pods, release_doc) }
    end

    # efficient pod fetching by querying once per cluster instead of once per deploy group
    def fetch_pods(release)
      release.clients.flat_map do |client, query|
        client.get_pods(query).map! do |p|
          pod = Kubernetes::Api::Pod.new(p)
          pod.client = client
          pod
        end
      end
    end

    def show_failure_cause(release, release_docs)
      pod_statuses(release, release_docs).reject(&:live).select(&:pod).each do |status|
        pod = status.pod
        deploy_group = deploy_group_for_pod(pod, release)
        @output.puts "\n#{deploy_group.name} pod #{pod.name}:"
        print_events(pod)
        @output.puts
        print_logs(pod)
        @output.puts "\n------------------------------------------\n"
      end
    end

    # show why container failed to boot
    def print_logs(pod)
      @output.puts "LOGS:"

      pod.containers.map(&:name).each do |container|
        @output.puts "Container #{container}" if pod.containers.size > 1

        # Display the first and last n_lines of the log
        max = 50
        lines = (pod.logs(container) || "No logs found").split("\n")
        lines = lines.first(max / 2) + ['...'] + lines.last(max / 2) if lines.size > max
        lines.each { |line| @output.puts "  #{line}" }
      end
    end

    # show what happened in kubernetes internally since we might not have any logs
    def print_events(pod)
      @output.puts "EVENTS:"
      events = pod.events
      events.uniq! { |e| e.message.split("\n").sort }
      events.each { |e| @output.puts "  #{e.reason}: #{e.message}" }
    end

    def unstable!
      @output.puts "UNSTABLE"
    end

    # user clicked stop button in UI
    def stopped?
      if @stopped
        @output.puts "STOPPED"
        true
      end
    end

    # TODO: cleanup ... a bit ugly with all these arrays
    def release_statuses(pods, release_doc)
      group = release_doc.deploy_group
      role = release_doc.kubernetes_role

      pods = pods.select { |pod| pod.role_id == role.id && pod.deploy_group_id == group.id }

      statuses = Array.new(release_doc.desired_pod_count).each_with_index.map do |_, i|
        pod = pods[i]

        if !pod
          [false, false, "Missing", pod]
        elsif pod.live?
          if pod.restarted?
            [false, true, "Restarted", pod]
          else
            [true, false, "Live", pod]
          end
        elsif pod.unschedulable?
          [false, true, "Unschedulable", pod]
        else
          [false, false, "Waiting (#{pod.phase}, #{pod.reason})", pod]
        end
      end

      statuses.map do |live, failed, details, pod|
        ReleaseStatus.new(live, failed, details, role.name, group.name, pod)
      end
    end

    def print_statuses(status_groups)
      return if @last_status_output && @last_status_output > 10.seconds.ago # FIX: increase TICK to 10 and remove this ?

      @last_status_output = Time.now
      @output.puts "Deploy status after #{seconds_waiting} seconds:"
      status_groups.group_by(&:group).each do |group, statuses|
        statuses.each do |status|
          @output.puts "  #{group} #{status.role}: #{status.details}"
        end
      end
    end

    def find_or_create_build
      return unless build = (Build.find_by_git_sha(@job.commit) || create_build)
      wait_for_build(build)
      ensure_build_is_successful(build) unless @stopped
      build
    end

    def wait_for_build(build)
      if !build.docker_repo_digest && build.docker_build_job.try(:active?)
        @output.puts("Waiting for Build #{build.url} to finish.")
        loop do
          break if @stopped
          sleep TICK
          break if build.docker_build_job.reload.finished?
        end
      end
      build.reload
    end

    def create_build
      if @job.project.repository.file_content('Dockerfile', @job.commit)
        @output.puts("Creating Build for #{@job.commit}.")
        build = Build.create!(
          git_sha: @job.commit,
          git_ref: @reference,
          creator: @job.user,
          project: @job.project,
          label: "Automated build triggered via Deploy ##{@job.deploy.id}"
        )
        DockerBuilderService.new(build).run!(push: true)
        build
      else
        @output.puts("Not creating a Build for #{@job.commit} since it does not have a Dockerfile.")
        false
      end
    end

    def ensure_build_is_successful(build)
      if build.docker_repo_digest
        @output.puts("Build #{build.url} is looking good!")
      elsif build_job = build.docker_build_job
        raise Samson::Hooks::UserError, "Build #{build.url} is #{build_job.status}, rerun it manually."
      else
        raise Samson::Hooks::UserError, "Build #{build.url} was created but never ran, run it manually."
      end
    end

    def rollback(release_docs)
      release_docs.each do |release_doc|
        action = release_doc.previous_deploy ? 'Rolling back' : 'Deleting'
        @output.puts "#{action} #{release_doc.deploy_group.name} role #{release_doc.kubernetes_role.name}"
        release_doc.revert
      end
    end

    # create a release, storing all the configuration
    def create_release(build)
      release = Kubernetes::Release.create_release(
        deploy_id: @job.deploy.id,
        deploy_groups: deploy_group_configs,
        build_id: build.try(:id),
        git_sha: @job.commit,
        git_ref: @reference,
        user: @job.user,
        project: @job.project
      )

      unless release.persisted?
        raise Samson::Hooks::UserError, "Failed to create release: #{release.errors.full_messages.inspect}"
      end

      @output.puts("Created release #{release.id}\nConfig: #{deploy_group_configs.to_json}")
      release
    end

    def deploy_group_configs
      @deploy_group_configs ||= begin
        # find role configs to avoid N+1s
        roles_configs = Kubernetes::DeployGroupRole.where(
          project_id: @job.project_id,
          deploy_group: @job.deploy.stage.deploy_groups.map(&:id)
        )

        # get all the roles that are configured for this sha
        configured_roles = Kubernetes::Role.configured_for_project(@job.project, @job.commit)
        if configured_roles.empty?
          raise Samson::Hooks::UserError, "No kubernetes config files found at sha #{@job.commit}"
        end

        # build config for every cluster and role we want to deploy to
        errors = []
        group_configs = @job.deploy.stage.deploy_groups.map do |group|
          roles = configured_roles.map do |role|
            role_config = roles_configs.detect do |dgr|
              dgr.deploy_group_id == group.id && dgr.kubernetes_role_id == role.id
            end

            unless role_config
              errors << "No config for role #{role.name} and group #{group.name} found, add it on the stage page."
              next
            end

            {
              role: role,
              replicas: role_config.replicas,
              cpu: role_config.cpu,
              ram: role_config.ram
            }
          end
          {deploy_group: group, roles: roles}
        end

        raise Samson::Hooks::UserError, errors.join("\n") if errors.any?
        group_configs
      end
    end

    def deploy(release_docs)
      release_docs.each do |release_doc|
        @output.puts "Creating for #{release_doc.deploy_group.name} role #{release_doc.kubernetes_role.name}"
        release_doc.deploy
      end
    end

    def deploy_to_cluster(release, release_docs)
      deploy(release_docs)
      successful = wait_for_resources_to_complete(release, release_docs)
      unless successful
        show_failure_cause(release, release_docs)
        rollback(release_docs)
        @output.puts "DONE"
      end
      successful
    end

    # Create the service or report it's status
    def ensure_service(release_docs)
      release_docs.each do |release_doc|
        role = release_doc.kubernetes_role
        status = release_doc.ensure_service # either succeeds or raises
        @output.puts "#{status} for role #{role.name} / service #{role.service_name.presence || "none"}"
      end
    end

    def success
      @output.puts "SUCCESS"
      true
    end

    def seconds_waiting
      (Time.now - @wait_start_time).to_i if @wait_start_time
    end

    # find deploy group without extra sql queries
    def deploy_group_for_pod(pod, release)
      release.release_docs.detect { |rd| break rd.deploy_group if rd.deploy_group_id == pod.deploy_group_id }
    end

    # verify with a temp release so we can verify everything before creating a real release
    # and having to wait for docker build to finish
    def verify_kubernetes_templates!
      release = Kubernetes::Release.new(project: @job.project, git_sha: @job.commit)
      deploy_group_configs.each do |config|
        config.fetch(:roles).each do |role|
          doc = Kubernetes::ReleaseDoc.new(
            kubernetes_release: release,
            deploy_group: config.fetch(:deploy_group),
            kubernetes_role: role.fetch(:role)
          )

          # verifies that config files are readable
          doc.deploy_template

          # verifies that secrets are findable
          template = Kubernetes::ResourceTemplate.new(doc)
          template.set_secrets
        end
      end
    end
  end
end
