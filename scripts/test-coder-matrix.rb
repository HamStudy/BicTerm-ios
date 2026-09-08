#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'fileutils'

class CoderMatrixTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.join(__dir__, 'verify-coder-matrix.rb')

  def setup
    @directory = Dir.mktmpdir('matrix-test-', File.join(ROOT, '.scratch'))
    @spec = File.join(@directory, 'spec.md')
    @matrix = File.join(@directory, 'matrix.md')
    @evidence = File.join(@directory, 'result.log')
    File.write(@evidence, "command: true\nexit: 0\n")
    @rows = ['| First case | Correct outcome. |', '| Second case | Another outcome. |']
    File.write(@spec, "### 18.1 Required MVP tests\n| Test | Expected result |\n|---|---|\n#{@rows.join("\n")}\n### 18.2 Other tests\n")
    @content = @rows.each_with_index.map do |row, index|
      "### A#{format('%02d', index + 1)}\n\n| Test | Expected result |\n|---|---|\n#{row}\n\n" \
        "- Status: PASS\n- Command: `true`\n- Evidence: `#{@evidence.delete_prefix(ROOT + '/')}`\n" \
        "- Reason: -\n- Detail: Executed successfully.\n"
    end.join("\n")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def verify(content, *options)
    File.write(@matrix, content)
    Open3.capture3(RbConfig.ruby, SCRIPT, '--spec', @spec, '--matrix', @matrix, *options)
  end

  def test_accepts_complete_evidenced_matrix
    _out, error, status = verify(@content)
    assert status.success?, error
  end

  def test_rejects_omitted_normative_row
    _out, _error, status = verify(@content.sub(@rows.first, ''))
    refute status.success?
  end

  def test_rejects_altered_expected_outcome
    _out, _error, status = verify(@content.sub('Correct outcome.', 'Wrong outcome.'))
    refute status.success?
  end

  def test_rejects_duplicate_row
    _out, _error, status = verify(@content + "\n#{@rows.first}\n")
    refute status.success?
  end

  def test_rejects_missing_evidence
    _out, _error, status = verify(@content.gsub('result.log', 'missing.log'))
    refute status.success?
  end

  def test_rejects_unexplained_not_local
    _out, _error, status = verify(@content.sub('Status: PASS', 'Status: NOT-LOCAL'))
    refute status.success?
  end

  def test_rejects_taxonomy_without_an_explanation
    content = @content.sub('Status: PASS', 'Status: NOT-LOCAL')
                      .sub('Reason: -', 'Reason: needs-private-CA')
                      .sub('Detail: Executed successfully.', 'Detail: -')
    _out, _error, status = verify(content)
    refute status.success?
  end

  def test_accepts_taxonomy_reason_with_explanation
    content = @content.sub('Status: PASS', 'Status: NOT-LOCAL').sub('Reason: -', 'Reason: needs-private-CA')
    _out, error, status = verify(content)
    assert status.success?, error
  end

  def test_gate_rejects_fail_without_hiding_matrix_completeness
    content = @content.sub('Status: PASS', 'Status: FAIL')
    _out, error, structural = verify(content)
    assert structural.success?, error
    _out, _error, gate = verify(content, '--gate')
    refute gate.success?
  end
end
