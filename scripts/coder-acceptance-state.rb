#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'

Dir.chdir(File.expand_path('..', __dir__))
name = ARGV.fetch(0)
wait_connected = ARGV[1] == '--wait-connected'
raise 'usage: workspace [--wait-connected]' unless ARGV.length <= 2 && (ARGV[1].nil? || wait_connected)
settings = File.readlines('Fixtures/run/coder-dev.env', chomp: true).to_h { |line| line.split('=', 2) }
url = URI(settings.fetch('CODER_URL'))
raise 'requires native loopback fixture' unless url.scheme == 'http' && url.host == '127.0.0.1' && url.port == 7080
request = Net::HTTP::Get.new('/api/v2/workspaces?q=owner:me')
request['Coder-Session-Token'] = settings.fetch('CODER_SESSION_TOKEN')
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
workspace = nil
loop do
  response = Net::HTTP.start(url.host, url.port, nil, open_timeout: 5, read_timeout: 15) do |http|
    http.request(request)
  end
  raise "HTTP #{response.code}" unless response.code == '200'
  workspace = JSON.parse(response.body).fetch('workspaces').find { |entry| entry.fetch('name') == name }
  raise 'workspace missing' unless workspace
  current_agents = workspace.fetch('latest_build').fetch('resources').flat_map { |resource| resource.fetch('agents', []) }
  break unless wait_connected
  break if workspace.dig('latest_build', 'status') == 'running' && !current_agents.empty? && current_agents.all? { |agent| agent.fetch('status') == 'connected' }
  raise 'agent readiness exceeded 60 seconds' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  sleep 0.2
end
build = workspace.fetch('latest_build')
agents = build.fetch('resources').flat_map do |resource|
  resource.fetch('agents', []).map do |agent|
    {
      resource: resource.fetch('name'), id: agent.fetch('id'), name: agent.fetch('name'),
      status: agent.fetch('status'), lifecycle: agent['lifecycle_state'],
      scripts: agent.fetch('scripts', []).map { |script| script.slice('display_name', 'start_blocks_login', 'run_on_start') }
    }
  end
end
puts JSON.pretty_generate(workspace_id: workspace.fetch('id'), build_id: build.fetch('id'), status: build.fetch('status'), agents: agents)
