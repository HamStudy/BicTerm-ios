#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'

root = File.expand_path('..', __dir__)
Dir.chdir(root)
settings = File.readlines('Fixtures/run/coder-dev.env', chomp: true).to_h { |line| line.split('=', 2) }
raise 'requires native loopback fixture' unless settings.fetch('CODER_URL') == 'http://127.0.0.1:7080'
environment = settings.slice('CODER_URL', 'CODER_SESSION_TOKEN').merge(
  'HOME' => "#{root}/.build-artifacts/Home",
  'XDG_CACHE_HOME' => "#{root}/.build-artifacts/Home/.cache",
  'TMPDIR' => "#{root}/.scratch/tmp"
)
logs = "#{root}/.sisyphus/evidence/phase2-g12-b-startup-cli"
FileUtils.mkdir_p(logs)

%w[blocking nonblocking].each do |variant|
  base = "#{root}/Fixtures/run/coder-acceptance/g12-startup-#{variant}"
  release = "#{base}/release-startup"
  completed = "#{base}/startup-completed"
  raise "#{variant}: prepare fresh held fixtures first" unless File.exist?("#{base}/startup-entered") && !File.exist?(release) && !File.exist?(completed)
  command = ['Fixtures/run/coder-bin/coder', 'ssh', '--disable-autostart', '--wait', 'auto',
             '--log-dir', logs, "g12-startup-#{variant}", '--', 'printf', 'g12-cli-connected']
  Open3.popen3(environment, *command, pgroup: true) do |input, output, errors, waiter|
    input.close
    stdout = Thread.new { output.read }
    stderr = Thread.new { errors.read }
    begin
      if variant == 'blocking'
        raise 'blocking CLI returned before script release' if waiter.join(3)
        raise 'blocking script completed before release' if File.exist?(completed)
        puts 'blocking: CLI pending with startup script held'
        File.write(release, '')
      end
      raise "#{variant}: CLI exceeded 30 seconds" unless waiter.join(30)
      raise "#{variant}: CLI failed with status #{waiter.value.exitstatus}" unless waiter.value.success?
      raise "#{variant}: remote command output missing" unless stdout.value == 'g12-cli-connected'
      if variant == 'nonblocking'
        raise 'nonblocking script completed before connection check' if File.exist?(completed) || File.exist?(release)
        puts 'nonblocking: remote command completed while startup script remained held'
      else
        raise 'blocking script did not complete' unless File.exist?(completed)
        puts 'blocking: remote command completed after startup script release'
      end
      File.write("#{logs}/#{variant}-stderr.log", stderr.value)
    ensure
      unless waiter.join(0)
        Process.kill('KILL', -waiter.pid)
        waiter.join
      end
      File.write(release, '') unless File.exist?(release)
      stdout.join
      stderr.join
    end
  end
end
puts 'PASS: pinned CLI auto-wait matches both native startup policy variants'
