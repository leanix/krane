# frozen_string_literal: true

module Krane
  class ClusterResourceDiscovery
    delegate :namespace, :context, :logger, to: :@task_config

    def initialize(task_config:, namespace_tags: [])
      @task_config = task_config
      @namespace_tags = namespace_tags
    end

    def crds
      @crds ||= fetch_crds.map do |cr_def|
        CustomResourceDefinition.new(namespace: namespace, context: context, logger: logger,
          definition: cr_def, statsd_tags: @namespace_tags)
      end
    end

    def prunable_resources(namespaced:)
      black_list = %w(Namespace Node ControllerRevision)
      fetch_resources(namespaced: namespaced).map do |resource|
        next unless resource["verbs"].one? { |v| v == "delete" }
        next if black_list.include?(resource["kind"])
        version = resource["version"]
        [resource["apigroup"], version, resource["kind"]].compact.join("/")
      end.compact
    end

    def fetch_resources(namespaced: false)
      api_paths.flat_map do |path|
        resources = fetch_api_path(path)["resources"] || []
        resources.map { |r| resource_hash(path, namespaced, r) }.compact
      end.uniq { |r| r["kind"] }
    end

    private

    def api_paths
      raw_json, err, st = kubectl.run("get", "--raw", "/", attempts: 5, use_namespace: false)
      paths = if st.success?
        JSON.parse(raw_json)["paths"]
      else
        raise FatalKubeAPIError, "Error retrieving raw path /: #{err}"
      end
      paths.select { |path| path.start_with?("/api") }
    end

    def fetch_api_path(path)
      raw_json, err, st = kubectl.run("get", "--raw", path, attempts: 5, use_namespace: false)
      if st.success?
        JSON.parse(raw_json)
      else
        logger.warn("Error retrieving api path: #{err}")
        {}
      end
    end

    def resource_hash(path, namespaced, blob)
      return unless blob["namespaced"] == namespaced
      # skip sub-resources
      return if blob["name"].include?("/")
      path_regex = %r{(/apis?/)(?<group>[^/]*)/?(?<version>v.+)}
      match = path.match(path_regex)
      {
        "verbs" => blob["verbs"],
        "kind" => blob["kind"],
        "apigroup" => match[:group],
        "version" => match[:version],
      }
    end

    def gvk_string(api_versions, resource)
      apiversion = resource['apiversion'].to_s

      ## In kubectl 1.20 APIGroups was replaced by APIVersions
      if apiversion.empty?
        apigroup = resource['apigroup'].to_s
        group_versions = api_versions[apigroup]

        version = version_for_kind(group_versions, resource['kind'])
        apigroup = 'core' if apigroup.empty?
        apiversion = "#{apigroup}/#{version}"
      end

      apiversion = "core/#{apiversion}" unless apiversion.include?("/")
      [apiversion, resource['kind']].compact.join("/")
    end

    def fetch_crds
      raw_json, err, st = kubectl.run("get", "CustomResourceDefinition", output: "json", attempts: 5,
        use_namespace: false)
      if st.success?
        JSON.parse(raw_json)["items"]
      else
        raise FatalKubeAPIError, "Error retrieving CustomResourceDefinition: #{err}"
      end
    end

    def kubectl
      @kubectl ||= Kubectl.new(task_config: @task_config, log_failure_by_default: true, default_timeout: 1)
    end
  end
end
