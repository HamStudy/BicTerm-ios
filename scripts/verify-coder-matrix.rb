#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'pathname'

ROOT = File.expand_path('..', __dir__)
TAXONOMY = %w[needs-live-deployment needs-physical-network needs-private-CA scope-explained other-explained].freeze
options = {
  spec: File.join(ROOT, 'CODER_WORKSPACE_SSH_PROTOCOL_SPEC.md'),
  matrix: File.join(ROOT, 'Docs/CODER-ACCEPTANCE-MATRIX.md')
}

begin
  OptionParser.new do |parser|
    parser.on('--spec PATH') { |value| options[:spec] = value }
    parser.on('--matrix PATH') { |value| options[:matrix] = value }
    parser.on('--generate', 'Write an explicitly unverified matrix; refuses overwrite') { options[:generate] = true }
    parser.on('--gate', 'Additionally reject any FAIL disposition') { options[:gate] = true }
  end.parse!
  raise ArgumentError, 'unexpected arguments' unless ARGV.empty?

  spec = File.read(options[:spec])
  section = spec.match(/^### 18\.1[^\n]*\n(.*?)^### 18\.2/m)
  raise ArgumentError, 'spec section 18.1 not found' unless section
  rows = section[1].lines.map(&:chomp).select { |line| line.start_with?('| ') }
  raise ArgumentError, 'unexpected spec table header' unless rows.shift == '| Test | Expected result |'
  raise ArgumentError, 'empty or duplicate normative rows' if rows.empty? || rows.uniq != rows

  if options[:generate]
    path = File.expand_path(options[:matrix])
    parent = File.realpath(File.dirname(path))
    raise ArgumentError, 'output must be repository-local' unless parent.start_with?(ROOT + '/')
    contents = "# Coder acceptance matrix\n\nGate: INCOMPLETE. FAIL includes unverified requirements.\n\n"
    rows.each_with_index do |row, index|
      contents += "### A#{format('%02d', index + 1)}\n\n| Test | Expected result |\n|---|---|\n#{row}\n\n"
      contents += "- Status: FAIL\n- Command: `ruby scripts/verify-coder-matrix.rb --gate`\n"
      contents += "- Evidence: `.sisyphus/evidence/phase2-g12-gate-brief.md`\n"
      contents += "- Reason: -\n- Detail: Acceptance outcome not yet demonstrated; gate remains closed.\n\n"
    end
    File.write(path, contents, mode: 'wx')
    puts "Generated #{rows.length} unverified normative rows: #{path}"
    exit 0
  end

  matrix = File.read(options[:matrix])
  actual = matrix.lines.map(&:chomp).select { |line| line.start_with?('| ') && line != '| Test | Expected result |' }
  raise ArgumentError, 'missing, altered, reordered, or duplicate normative rows' unless actual == rows
  blocks = matrix.split(/^### A/).drop(1)
  raise ArgumentError, 'one disposition block required per normative row' unless blocks.length == rows.length
  statuses = []
  blocks.each_with_index do |block, index|
    id = format('%02d', index + 1)
    raise ArgumentError, "incorrect row identity A#{id}" unless block.start_with?(id + "\n") && block.lines.map(&:chomp).include?(rows[index])
    fields = {}
    block.scan(/^- (Status|Command|Evidence|Reason|Detail): (.*)$/) do |key, value|
      raise ArgumentError, "A#{id}: duplicate #{key}" if fields.key?(key)
      fields[key] = value
    end
    unless %w[Status Command Evidence Reason Detail].all? { |key| fields[key] && !fields[key].strip.empty? }
      raise ArgumentError, "A#{id}: missing disposition fields"
    end
    status = fields.fetch('Status')
    raise ArgumentError, "A#{id}: invalid status" unless %w[PASS NOT-LOCAL FAIL].include?(status)
    reason = fields.fetch('Reason')
    valid_reason = status == 'NOT-LOCAL' ? TAXONOMY.include?(reason) : reason == '-'
    raise ArgumentError, "A#{id}: invalid taxonomy reason" unless valid_reason
    raise ArgumentError, "A#{id}: missing explanation" if fields.fetch('Detail').strip == '-'
    raise ArgumentError, "A#{id}: command must be inline code" unless fields.fetch('Command').match?(/\A`[^`]+`\z/)
    evidence = fields.fetch('Evidence').match(/\A`([^`]+)`\z/)
    raise ArgumentError, "A#{id}: evidence must be a relative path" unless evidence && Pathname.new(evidence[1]).relative?
    path = File.realpath(File.join(ROOT, evidence[1]))
    unless path.start_with?(ROOT + '/') && File.file?(path) && File.size(path).positive?
      raise ArgumentError, "A#{id}: missing or external evidence"
    end
    statuses << status
  end
  counts = statuses.tally.map { |status, count| "#{status}=#{count}" }.join(', ')
  puts "Matrix structure verified: #{rows.length} verbatim rows; #{counts}. Evidence existence is not proof of acceptance."
  raise ArgumentError, 'phase gate INCOMPLETE: FAIL rows remain' if options[:gate] && statuses.include?('FAIL')
rescue ArgumentError, OptionParser::ParseError, SystemCallError => error
  warn error.message
  exit 1
end
