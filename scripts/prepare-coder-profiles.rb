#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'net/http'
require 'securerandom'

root = File.expand_path('..', __dir__)
Dir.chdir(root)
settings = File.readlines('Fixtures/run/coder-dev.env', chomp: true).to_h { |line| line.split('=', 2) }
url = URI(settings.fetch('CODER_URL'))
raise 'requires native loopback fixture' unless url.to_s == 'http://127.0.0.1:7080'
admin = settings.fetch('CODER_SESSION_TOKEN')
environment = {
  'CODER_URL' => url.to_s, 'HOME' => "#{root}/.build-artifacts/Home",
  'XDG_CACHE_HOME' => "#{root}/.build-artifacts/Home/.cache", 'TMPDIR' => "#{root}/.scratch/tmp",
  'CODER_CONFIG_DIR' => "#{root}/Fixtures/run/coder-dev/config",
  'CODER_CACHE_DIRECTORY' => "#{root}/Fixtures/run/coder-dev/cache", 'CODER_USE_KEYRING' => 'false'
}
request = lambda do |token, method, path, expected, body = nil|
  headers = { 'Content-Type' => 'application/json' }
  headers['Coder-Session-Token'] = token if token
  message = Net::HTTPGenericRequest.new(method, !body.nil?, true, path, headers)
  message.body = JSON.generate(body) if body
  response = Net::HTTP.start(url.host, url.port, nil, open_timeout: 5, read_timeout: 15) { |http| http.request(message) }
  raise "#{method} #{path}: HTTP #{response.code}, expected #{expected}" unless response.code.to_i == expected
  response.body.to_s.empty? ? nil : JSON.parse(response.body)
end
coder = lambda do |token, *arguments|
  raise 'Coder profile fixture command failed' unless system(environment.merge('CODER_SESSION_TOKEN' => token), 'Fixtures/run/coder-bin/coder', *arguments, in: File::NULL)
end
file = 'Fixtures/run/coder-acceptance/profiles.json'
profiles = File.exist?(file) ? JSON.parse(File.read(file)) : []
identity = request.call(admin, 'GET', '/api/v2/users/me', 200)
coder.call(admin, 'templates', 'push', 'bicterm-profiles', '-d', 'Fixtures/coder/acceptance-template', '--yes', '--activate')
%w[a b].each_with_index do |label, index|
  profile = profiles[index]
  unless profile
    suffix = SecureRandom.hex(4)
    password = SecureRandom.base64(24) + 'A1!'
    user = request.call(admin, 'POST', '/api/v2/users', 201, {
      email: "g12-profile-#{suffix}@fixture.invalid", username: "g12-profile-#{suffix}",
      password: password, login_type: 'password', user_status: 'active',
      organization_ids: identity.fetch('organization_ids')
    })
    login = request.call(nil, 'POST', '/api/v2/users/login', 201, email: user.fetch('email'), password: password)
    profile = { 'user_id' => user.fetch('id'), 'token' => login.fetch('session_token'), 'name' => "g12-profile-#{label}-#{suffix}" }
    profiles[index] = profile
    File.open(file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |output| output.write(JSON.pretty_generate(profiles)) }
  end
  token = profile.fetch('token')
  user = request.call(token, 'GET', '/api/v2/users/me', 200)
  raise 'profile identity mismatch' unless user.fetch('id') == profile.fetch('user_id') && user.fetch('id') != identity.fetch('id')
  raise 'profile must not be a deployment administrator' if user.fetch('roles', []).any? { |role| %w[owner user-admin].include?(role.fetch('name')) }
  name = profile.fetch('name')
  workspaces = request.call(token, 'GET', '/api/v2/workspaces?q=owner:me', 200).fetch('workspaces')
  if workspaces.any? { |workspace| workspace.fetch('name') == name }
    coder.call(token, 'update', name, '--parameter', 'multi_agent=false', '--parameter', 'script_mode=normal', '--parameter', 'start_blocks_login=true')
  else
    coder.call(token, 'create', name, '--template', 'bicterm-profiles', '--yes', '--parameter', 'multi_agent=false', '--parameter', 'script_mode=normal', '--parameter', 'start_blocks_login=true')
  end
  base = "Fixtures/run/coder-acceptance/#{name}"
  pid_file = "#{base}/main.pid"
  if File.exist?(pid_file)
    pid = Integer(File.read(pid_file).strip)
    begin
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
      nil
    end
  end
  log = File.open("#{base}/main.log", 'a')
  pid = Process.spawn('/bin/bash', "#{base}/main.sh", in: File::NULL, out: log, err: log, pgroup: true)
  Process.detach(pid)
  log.close
  File.write(pid_file, "#{pid}\n")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
  loop do
    workspace = request.call(token, 'GET', '/api/v2/workspaces?q=owner:me', 200).fetch('workspaces').find { |entry| entry.fetch('name') == name }
    agents = workspace.fetch('latest_build').fetch('resources').flat_map { |resource| resource.fetch('agents', []) }
    if agents.length == 1 && agents.first.fetch('status') == 'connected' && agents.first.fetch('lifecycle_state') == 'ready'
      profile['agent_id'] = agents.first.fetch('id')
      break
    end
    raise 'profile agent readiness exceeded 60 seconds' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.2
  end
  puts "PROFILE #{label} user=#{profile.fetch('user_id')} agent=#{profile.fetch('agent_id')} connected and ready"
end
raise 'profiles must have distinct identities and agents' unless profiles.map { |profile| profile.fetch('user_id') }.uniq.length == 2 && profiles.map { |profile| profile.fetch('agent_id') }.uniq.length == 2
profiles.each_with_index do |profile, index|
  own_path = "/api/v2/workspaceagents/#{profile.fetch('agent_id')}/connection"
  other_path = "/api/v2/workspaceagents/#{profiles[1 - index].fetch('agent_id')}/connection"
  request.call(profile.fetch('token'), 'GET', own_path, 200)
  request.call(profile.fetch('token'), 'GET', other_path, 404)
  puts "PROFILE #{index} own agent authorized; other profile agent denied with 404"
end
File.open(file, File::WRONLY | File::TRUNC, 0o600) { |output| output.write(JSON.pretty_generate(profiles)) }
puts 'READY: two distinct non-administrator profiles with mutually denied cross-agent access'
