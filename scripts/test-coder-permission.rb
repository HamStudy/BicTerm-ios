#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'open3'
require 'securerandom'
require 'timeout'

class PermissionFixtureAPI
  def initialize(url, token = nil)
    @url = url
    @token = token
  end

  def request(method, path, body = nil)
    headers = { 'Content-Type' => 'application/json' }
    headers['Coder-Session-Token'] = @token if @token
    request = Net::HTTPGenericRequest.new(method, !body.nil?, true, path, headers)
    request.body = JSON.generate(body) if body
    response = Net::HTTP.start(@url.host, @url.port, nil, open_timeout: 5, read_timeout: 15) do |http|
      http.request(request)
    end
    puts "HTTP #{method} #{path} status=#{response.code}"
    response
  end
end

def expect_status(response, status)
  raise "expected HTTP #{status}, got #{response.code}" unless response.code.to_i == status
  response.body.empty? ? nil : JSON.parse(response.body)
end

root = File.expand_path('..', __dir__)
Dir.chdir(root)
settings = File.readlines('Fixtures/run/coder-dev.env', chomp: true).to_h { |line| line.split('=', 2) }
url = URI(settings.fetch('CODER_URL'))
raise 'requires native loopback fixture' unless url.scheme == 'http' && url.host == '127.0.0.1' && url.port == 7080
owner = PermissionFixtureAPI.new(url, settings.fetch('CODER_SESSION_TOKEN'))
identity = expect_status(owner.request('GET', '/api/v2/users/me'), 200)
workspaces = expect_status(owner.request('GET', '/api/v2/workspaces?q=owner:me'), 200).fetch('workspaces')
workspace = workspaces.find { |entry| entry.fetch('name') == 'bicterm-host' }
raise 'native workspace missing' unless workspace
agent = workspace.fetch('latest_build').fetch('resources').flat_map { |entry| entry.fetch('agents', []) }.first
raise 'native agent missing' unless agent
path = "/api/v2/workspaceagents/#{agent.fetch('id')}/connection"
expect_status(owner.request('GET', path), 200)

suffix = SecureRandom.hex(4)
password = SecureRandom.base64(24) + 'A1!'
user_id = nil
begin
  created = expect_status(owner.request('POST', '/api/v2/users', {
    email: "g12-#{suffix}@fixture.invalid", username: "g12-#{suffix}",
    password: password, login_type: 'password', user_status: 'active',
    organization_ids: identity.fetch('organization_ids')
  }), 201)
  user_id = created.fetch('id')
  login = expect_status(PermissionFixtureAPI.new(url).request('POST', '/api/v2/users/login', {
    email: created.fetch('email'), password: password
  }), 201)
  outsider_token = login.fetch('session_token')
  outsider = PermissionFixtureAPI.new(url, outsider_token)
  outsider_identity = expect_status(outsider.request('GET', '/api/v2/users/me'), 200)
  raise 'authenticated identity mismatch' unless outsider_identity.fetch('id') == user_id && user_id != identity.fetch('id')
  expect_status(outsider.request('GET', path), 404)

  config = {
    server_url: url.to_s, session_token: outsider_token, agent_id: agent.fetch('id'),
    socket_dir: File.join(root, 'Fixtures/run/g12s'), relay_only: false
  }
  output, diagnostic, status = Timeout.timeout(100) do
    Open3.capture3(File.join(root, '.build-artifacts/coder-g12-host/raw-adapter'), stdin_data: JSON.generate(config) + "\n")
  end
  raise 'denied profile acquired a raw socket' unless output.empty? && status.exitstatus == 4
  raise 'bridge did not retain 404 denial diagnostics' unless diagnostic.include?('404')
  raise 'credential leaked in bridge diagnostic' if diagnostic.include?(outsider_token) || diagnostic.include?(password)
  File.write('.sisyphus/evidence/phase2-g12-b-permission-bridge.log', diagnostic)
  expect_status(owner.request('GET', path), 200)
  puts 'PASS A03 authenticated outsider receives hidden 404; production bridge refuses dial; owner remains authorized'
ensure
  expect_status(owner.request('DELETE', "/api/v2/users/#{user_id}"), 200) if user_id
end
