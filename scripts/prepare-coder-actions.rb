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
environment = settings.slice('CODER_URL', 'CODER_SESSION_TOKEN').merge(
  'HOME' => "#{root}/.build-artifacts/Home",
  'XDG_CACHE_HOME' => "#{root}/.build-artifacts/Home/.cache",
  'TMPDIR' => "#{root}/.scratch/tmp",
  'CODER_CONFIG_DIR' => "#{root}/Fixtures/run/coder-dev/config",
  'CODER_CACHE_DIRECTORY' => "#{root}/Fixtures/run/coder-dev/cache",
  'CODER_USE_KEYRING' => 'false'
)
request = lambda do |method, path, body = nil|
  klass = { get: Net::HTTP::Get, put: Net::HTTP::Put }.fetch(method)
  message = klass.new(path)
  message['Coder-Session-Token'] = settings.fetch('CODER_SESSION_TOKEN')
  if body
    message['Content-Type'] = 'application/json'
    message.body = JSON.generate(body)
  end
  response = Net::HTTP.start(url.host, url.port, nil, open_timeout: 5, read_timeout: 15) { |http| http.request(message) }
  raise "#{method} #{path}: HTTP #{response.code}" unless response.code.to_i.between?(200, 299) || response.code == '304'
  response.body.to_s.empty? ? nil : JSON.parse(response.body)
end
coder = lambda do |*arguments|
  raise 'Coder fixture command failed' unless system(environment, 'Fixtures/run/coder-bin/coder', *arguments, in: File::NULL)
end
template = '.scratch/coder-actions-template'
FileUtils.mkdir_p(template)
FileUtils.cp('Fixtures/coder/acceptance-template/main.tf', "#{template}/main.tf")
coder.call('templates', 'push', 'bicterm-actions', '-d', template, '--yes', '--activate')
workspaces = request.call(:get, '/api/v2/workspaces?q=owner:me').fetch('workspaces')
snapshot = {}
%w[dormant parameters].each do |variant|
  name = "g12-action-#{variant}"
  existing = workspaces.find { |workspace| workspace.fetch('name') == name }
  if existing
    request.call(:put, "/api/v2/workspaces/#{existing.fetch('id')}/dormant", dormant: false)
    coder.call('update', name, '--parameter', 'multi_agent=false', '--parameter', 'script_mode=normal', '--parameter', 'start_blocks_login=true')
  else
    coder.call('create', name, '--template', 'bicterm-actions', '--yes', '--parameter', 'multi_agent=false', '--parameter', 'script_mode=normal', '--parameter', 'start_blocks_login=true')
  end
  coder.call('stop', name, '--yes')
  workspace = request.call(:get, '/api/v2/workspaces?q=owner:me').fetch('workspaces').find { |entry| entry.fetch('name') == name }
  id = workspace.fetch('id')
  if variant == 'dormant'
    request.call(:put, "/api/v2/workspaces/#{id}/dormant", dormant: true)
  else
    request.call(:put, "/api/v2/workspaces/#{id}/autoupdates", automatic_updates: 'always')
  end
  snapshot[variant] = id
end
parameter = "explicit_confirmation_#{SecureRandom.hex(4)}"
File.open("#{template}/main.tf", 'a') do |file|
  file.puts "\ndata \"coder_parameter\" \"confirmation\" {\n  name = \"#{parameter}\"\n  type = \"string\"\n  mutable = true\n}"
end
coder.call('templates', 'push', 'bicterm-actions', '-d', template, '--yes', '--activate')
mismatch = request.call(:get, "/api/v2/workspaces/#{snapshot.fetch('parameters')}/resolve-autostart")
raise 'native parameter mismatch was not established' unless mismatch.fetch('parameter_mismatch')
dormant = request.call(:get, "/api/v2/workspaces/#{snapshot.fetch('dormant')}")
raise 'native dormancy was not established' unless dormant['dormant_at']
File.write('Fixtures/run/coder-acceptance/action-workspaces.json', JSON.pretty_generate(snapshot))
puts 'READY: native dormant workspace and required-parameter mismatch; no agents launched'
