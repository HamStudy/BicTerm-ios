#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'timeout'

root = File.expand_path('..', __dir__)
names = ARGV
raise 'expected acceptance workspace names' if names.empty? || names.any? { |name| !name.match?(/\Ag12-[a-z0-9-]+\z/) }
paths = names.flat_map { |name| %w[main sidecar].map { |agent| File.join(root, 'Fixtures/run/coder-acceptance', name, "#{agent}.sh") } }
seen = paths.to_h { |path| [path, File.exist?(path) ? Digest::SHA256.file(path).hexdigest : nil] }
children = {}
stopping = false
Signal.trap('TERM') { stopping = true }
Signal.trap('INT') { stopping = true }
$stdout.sync = true

def stop_child(pid)
  Process.kill('TERM', -pid)
  begin
    Timeout.timeout(5) { Process.waitpid(pid) }
  rescue Timeout::Error
    Process.kill('KILL', -pid)
    Process.waitpid(pid)
  end
rescue Errno::ESRCH, Errno::ECHILD
  nil
end

begin
  puts 'WATCHER_READY'
  until stopping
    paths.each do |path|
      next unless File.exist?(path)
      fingerprint = Digest::SHA256.file(path).hexdigest
      next if seen[path] == fingerprint
      stop_child(children.delete(path)) if children.key?(path)
      log = path.sub(/\.sh\z/, '.log')
      pid = Process.spawn('/bin/bash', path, in: File::NULL, out: [log, 'a'], err: [:child, :out], pgroup: true)
      children[path] = pid
      File.write(path.sub(/\.sh\z/, '.pid'), "#{pid}\n")
      seen[path] = fingerprint
      puts "AGENT_STARTED #{File.basename(File.dirname(path))}/#{File.basename(path)}"
    end
    sleep 0.1
  end
ensure
  children.each do |path, pid|
    stop_child(pid)
    pid_file = path.sub(/\.sh\z/, '.pid')
    File.delete(pid_file) if File.exist?(pid_file) && File.read(pid_file).strip == pid.to_s
  end
  puts 'WATCHER_STOPPED'
end
