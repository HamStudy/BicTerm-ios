#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'cgi'
require 'digest'
require 'json'

Dir.chdir(File.expand_path('..', __dir__))
settings = File.readlines('Fixtures/run/coder-dev.env', chomp: true).to_h { |line| line.split('=', 2) }
profiles = JSON.parse(File.read('Fixtures/run/coder-acceptance/profiles.json'))
base = 'Fixtures/run/coder-acceptance/g12-control'
keys = Dir.glob('Fixtures/keys/*').select { |path| File.file?(path) }.filter_map do |path|
  bytes = File.binread(path)
  bytes if bytes.include?('PRIVATE KEY-----')
end
categories = {
  user_tokens: [settings.fetch('CODER_SESSION_TOKEN'), *profiles.map { |profile| profile.fetch('token') }],
  resume_tokens: JSON.parse(File.read("#{base}/resume-secrets.json")) + ['g12-invalid-resume-token'],
  private_keys: keys.flat_map { |key| [key, *key.lines.map(&:strip).reject { |line| line.start_with?('-----') || line.length < 32 }] },
  terminal_contents: JSON.parse(File.read("#{base}/terminal-sentinels.json"))
}
patterns = categories.transform_values do |values|
  raise 'empty audit category' if values.empty? || values.any?(&:empty?)
  values.flat_map { |value| [value.b, CGI.escape(value).b, Base64.strict_encode64(value).b] }.uniq
end
detect = lambda do |bytes|
  patterns.filter_map { |category, needles| category if needles.any? { |needle| bytes.include?(needle) } }
end
patterns.each do |category, needles|
  needles.each do |needle|
    raise "positive control failed for #{category}" unless detect.call("prefix\n".b + needle + "\nsuffix".b).include?(category)
  end
end
raise 'negative control failed' unless detect.call('ordinary diagnostic status=200'.b).empty?

excluded = %w[phase2-g12-final-log-audit.log phase2-g12-final-log-audit.json]
files = Dir.glob('.sisyphus/evidence/**/*').select do |path|
  File.file?(path) && path.split('/').any? { |part| part.start_with?('phase2-g12') } &&
    %w[.log .md .json .txt].include?(File.extname(path)) && !excluded.include?(File.basename(path))
end.sort
raise 'no T12 logs found' if files.empty?
leaks = []
manifest = files.map do |path|
  bytes = File.binread(path)
  found = detect.call(bytes)
  found << :private_key_header if bytes.match?(/-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----/)
  found << :jwt if bytes.match?(/\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\b/)
  leaks << { path: path, categories: found.uniq } unless found.empty?
  { path: path, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize }
end
result = {
  passed: leaks.empty?, positive_controls: patterns.transform_values(&:length),
  files_scanned: files.length, leaks: leaks, files: manifest
}
File.write('.sisyphus/evidence/phase2-g12-final-log-audit.json', JSON.pretty_generate(result))
unless leaks.empty?
  leaks.each { |leak| warn "LEAK #{leak.fetch(:path)} categories=#{leak.fetch(:categories).join(',')}" }
  exit 1
end
puts "PASS: #{files.length} T12 scenario logs/documents scanned with SHA-256 manifest"
patterns.each { |category, needles| puts "PASS #{category}: #{needles.length} raw/URL/base64 patterns; positive controls passed" }
puts 'PASS: no private-key headers or JWT-shaped values found'
