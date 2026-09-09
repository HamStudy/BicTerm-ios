#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'net/http'
require 'open3'
require 'timeout'

ROOT = File.expand_path('..', __dir__)
FAILURES = []
Dir.chdir(ROOT)
settings = File.readlines('Fixtures/run/coder-dev.env', chomp: true).to_h { |line| line.split('=', 2) }
url = URI(ENV.fetch('CODER_GATE_URL', settings.fetch('CODER_URL')))
raise 'requires the local native fixture or its proxy' unless url.host == '127.0.0.1' && [7080, 7081].include?(url.port)
request = Net::HTTP::Get.new('/api/v2/workspaces?q=owner:me&limit=100&offset=0')
request['Coder-Session-Token'] = settings.fetch('CODER_SESSION_TOKEN')
response = Net::HTTP.start(url.host, url.port, nil) { |http| http.request(request) }
raise "workspace discovery HTTP #{response.code}" unless response.code == '200'
workspace = JSON.parse(response.body).fetch('workspaces').find { |entry| entry.fetch('name') == 'bicterm-host' }
raise 'running fixture workspace missing' unless workspace && workspace.dig('latest_build', 'status') == 'running'
agents = workspace.fetch('latest_build').fetch('resources').flat_map { |resource| resource.fetch('agents', []) }
agent = agents.find { |entry| entry.fetch('status') == 'connected' }
raise 'connected fixture agent missing' unless agent

config = {
  server_url: url.to_s,
  session_token: settings.fetch('CODER_SESSION_TOKEN'),
  agent_id: agent.fetch('id'),
  socket_dir: File.join(ROOT, 'Fixtures/run/g12s'),
  relay_only: ENV['CODER_GATE_RELAY_ONLY'] == '1'
}
binary = File.join(ROOT, '.build-artifacts/coder-g12-host/raw-adapter')
mode = config[:relay_only] ? 'relay' : 'direct'
log_path = File.join(ROOT, ".sisyphus/evidence/phase2-g12-final-raw-bridge-#{mode}.log")
bridge_in, bridge_out, bridge_err, bridge_thread = Open3.popen3(binary)
diagnostics = Thread.new { File.binwrite(log_path, bridge_err.read) }
socket = nil

def check(name)
  yield
  puts "PASS #{name}"
rescue StandardError => error
  FAILURES << name
  puts "FAIL #{name}: #{error.class}: #{error.message}"
end

def ssh_process(ssh, command)
  Open3.popen3(*ssh, command, pgroup: true) do |input, output, error, process|
    begin
      Timeout.timeout(15) { yield input, output, error, process }
    ensure
      if process.alive?
        Process.kill('TERM', -process.pid)
        Process.kill('KILL', -process.pid) unless process.join(3)
      end
    end
  end
end

begin
  bridge_in.puts(JSON.generate(config))
  bridge_in.flush
  socket = Timeout.timeout(100) { bridge_out.gets }&.strip
  raise 'bridge failed before exposing a socket' unless socket && File.socket?(socket)
  ssh = [
    '/usr/bin/ssh', '-F', '/dev/null', '-T',
    '-o', "ProxyCommand=/usr/bin/nc -U #{socket}",
    '-o', 'UserKnownHostsFile=/dev/null', '-o', 'GlobalKnownHostsFile=/dev/null',
    '-o', 'StrictHostKeyChecking=no', '-o', 'LogLevel=ERROR',
    '-o', 'PreferredAuthentications=none', '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=15', 'coder@coder-workspace'
  ]
  run = lambda do |command, input = ''|
    puts "COMMAND /usr/bin/ssh [recorded fixed options] coder@coder-workspace #{command.inspect}"
    Timeout.timeout(90) { Open3.capture3(*ssh, command, stdin_data: input, binmode: true) }
  end
  puts "Fixture Coder v2.36.4; bridge source built from CoderNet/; relay_only=#{config[:relay_only]}"
  puts "SSH_OPTIONS #{ssh[0...-1].inspect}"

  check('A01 OpenSSH command over production raw adapter') do
    out, err, status = run.call('printf raw-adapter-ok')
    raise "command failed: status=#{status.exitstatus}, stdout_bytes=#{out.bytesize}, stderr_bytes=#{err.bytesize}" unless status.success? && out == 'raw-adapter-ok' && err.empty?
  end
  check('A25 binary stdout byte-exact without PTY') do
    out, err, status = run.call("/usr/bin/printf '\\000\\001\\012\\015\\177\\200\\377'")
    raise 'binary mismatch' unless status.success? && err.empty? && out.bytes == [0, 1, 10, 13, 127, 128, 255]
  end
  check('A26 stderr and remote exit status preserved') do
    out, err, status = run.call('printf stdout-marker; printf stderr-marker >&2; exit 37')
    raise 'status/streams mismatch' unless status.exitstatus == 37 && out == 'stdout-marker' && err == 'stderr-marker'
  end
  check('A27 more than 4 MiB streamed intact') do
    out, err, status = run.call('/bin/dd if=/dev/zero bs=1048576 count=5 2>/dev/null')
    expected = "\0" * (5 * 1024 * 1024)
    raise 'stream mismatch' unless status.success? && err.empty? && out.bytesize == expected.bytesize && Digest::SHA256.digest(out) == Digest::SHA256.digest(expected)
    puts "BYTES #{out.bytesize}; SHA256 #{Digest::SHA256.hexdigest(out)}"
  end
  check('A30 stdin EOF drains trailing remote output') do
    input = "binary-input\0\xff".b
    out, err, status = run.call('/bin/cat; /bin/sleep 1; printf trailing-output', input)
    raise 'half-close truncated output' unless status.success? && err.empty? && out == input + 'trailing-output'
  end
  check('control rebind preserves subsequent SSH use') do
    bridge_in.puts('r')
    bridge_in.flush
    out, err, status = run.call('printf after-rebind')
    raise 'rebind failure' unless status.success? && err.empty? && out == 'after-rebind'
  end
  check('A31 stdout failure terminates an unbounded producer') do
    puts 'COMMAND OpenSSH /usr/bin/yes output-failure; close local stdout reader'
    ssh_process(ssh, '/usr/bin/yes output-failure') do |input, output, error, process|
      input.close
      output.close
      error.read
      raise 'stdout failure unexpectedly succeeded' if process.value.success?
    end
  end
  check('A31 active handle cancellation closes the SSH session') do
    puts 'COMMAND OpenSSH /bin/cat; exchange marker; close bridge control input'
    ssh_process(ssh, '/bin/cat') do |input, output, error, process|
      marker = 'active-session-marker'
      input.write(marker)
      input.flush
      raise 'active SSH stream did not echo before cancellation' unless output.read(marker.bytesize) == marker
      bridge_in.close
      raise 'cancelled SSH session unexpectedly succeeded' if process.value.success?
      error.read
    end
  end
ensure
  bridge_in.close unless bridge_in.closed?
  begin
    Timeout.timeout(15) { bridge_thread.value }
  rescue Timeout::Error
    Process.kill('TERM', bridge_thread.pid)
    bridge_thread.value
    raise 'bridge did not close within 15 seconds'
  ensure
    diagnostics.join
    bridge_out.close
    bridge_err.close
  end
end
raise 'bridge socket leaked after close' if socket && File.exist?(socket)
raise 'bridge exited unsuccessfully' unless bridge_thread.value.success?
puts 'PASS bridge close removed socket and terminated process'
log = File.binread(log_path)
expected_path = ENV.fetch('CODER_GATE_EXPECT_PATH', config[:relay_only] ? 'relayed' : 'direct')
raise 'expected path must be direct or relayed' unless %w[direct relayed].include?(expected_path)
raise "expected observed path #{expected_path}" unless log.include?(%Q("path":"#{expected_path}"))
puts log.lines.find { |line| line.include?(%Q("path":"#{expected_path}")) }
puts "PASS observed network path #{expected_path}"
raise 'user token leaked in bridge diagnostics' if log.include?(settings.fetch('CODER_SESSION_TOKEN'))
raise 'terminal data leaked in bridge diagnostics' if log.include?('stdout-marker') || log.include?('trailing-output')
puts 'PASS limited user-token/terminal-content diagnostic scan (not the full four-category audit)'
exit(FAILURES.empty? ? 0 : 1)
