#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'socket'
require 'uri'

Dir.chdir(File.expand_path('..', __dir__))
mode = ARGV.fetch(0)
raise 'expected reset or resume mode' unless %w[reset resume].include?(mode)
base = 'Fixtures/run/coder-acceptance/g12-control'
server = TCPServer.new('127.0.0.1', 0)
mutex = Mutex.new
connections = []
controls = []
workers = []
attempts = []
injected = false
stopping = false
File.write("#{base}/proxy.json", JSON.generate(url: "http://127.0.0.1:#{server.addr[1]}", mode: mode))
publish = lambda do
  File.write("#{base}/control-ledger.json.tmp", JSON.generate(attempts: attempts))
  File.rename("#{base}/control-ledger.json.tmp", "#{base}/control-ledger.json")
end
mutex.synchronize { publish.call }
monitor = Thread.new do
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
  loop do
    break if mutex.synchronize { stopping }
    if File.exist?("#{base}/reset-request")
      File.unlink("#{base}/reset-request")
      sockets = mutex.synchronize { controls.dup }
      sockets.each { |socket| socket.close unless socket.closed? }
      puts 'CONTROL_RESET closed coordinator sockets only'
      $stdout.flush
    end
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      server.close
      break
    end
    sleep 0.05
  end
end
Signal.trap('TERM') { server.close }
begin
  loop do
    incoming = server.accept
    mutex.synchronize { connections << incoming }
    workers << Thread.new(incoming) do |client|
      upstream = nil
      pumps = []
      begin
        header = client.gets("\r\n\r\n", 65_536)
        raise IOError, 'incomplete HTTP header' unless header&.end_with?("\r\n\r\n")
        lines = header.split("\r\n")
        method, target, version = lines.fetch(0).split(' ', 3)
        uri = URI(target)
        coordinate = uri.path.end_with?('/coordinate')
        attempt = nil
        if coordinate
          query = URI.decode_www_form(uri.query.to_s).to_h
          resume_present = !query.fetch('resume_token', '').empty?
          mutex.synchronize do
            if resume_present
              secret_path = "#{base}/resume-secrets.json"
              secrets = File.exist?(secret_path) ? JSON.parse(File.read(secret_path)) : []
              secrets << query.fetch('resume_token')
              File.open(secret_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(secrets.uniq)) }
            end
            corrupt = mode == 'resume' && resume_present && !injected
            if corrupt
              query['resume_token'] = 'g12-invalid-resume-token'
              uri.query = URI.encode_www_form(query)
              lines[0] = "#{method} #{uri} #{version}"
              injected = true
            end
            attempt = { resume_present: resume_present, injected: corrupt, status: nil }
            attempts << attempt
            publish.call
          end
        end
        lines.reject! { |line| line.downcase.start_with?('connection:') }
        lines << (coordinate ? 'Connection: Upgrade, close' : 'Connection: close')
        upstream = Socket.tcp('127.0.0.1', 7080, connect_timeout: 5)
        mutex.synchronize { connections << upstream }
        upstream.write(lines.join("\r\n") + "\r\n\r\n")
        response = upstream.gets("\r\n\r\n", 65_536)
        raise IOError, 'incomplete HTTP response' unless response&.end_with?("\r\n\r\n")
        if coordinate
          status = Integer(response.lines.first.split(' ')[1])
          mutex.synchronize do
            attempt[:status] = status
            controls.concat([client, upstream]) if status == 101
            publish.call
          end
          puts "COORDINATOR resume_present=#{attempt[:resume_present]} injected=#{attempt[:injected]} status=#{status}"
          $stdout.flush
        end
        client.write(response)
        pumps = [[client, upstream], [upstream, client]].map do |source, destination|
          Thread.new do
            begin
              IO.copy_stream(source, destination)
            rescue IOError, SystemCallError
              nil
            ensure
              source.close unless source.closed?
              destination.close unless destination.closed?
            end
          end
        end
        pumps.each(&:join)
      rescue IOError, SystemCallError, URI::InvalidURIError => error
        warn "proxy connection ended: #{error.class}"
      ensure
        client.close unless client.closed?
        upstream.close if upstream && !upstream.closed?
        pumps.each(&:join)
      end
    end
  end
rescue IOError, Errno::EBADF
  nil
ensure
  mutex.synchronize do
    stopping = true
    connections.each { |socket| socket.close unless socket.closed? }
  end
  server.close unless server.closed?
  monitor.join
  workers.each(&:join)
end
