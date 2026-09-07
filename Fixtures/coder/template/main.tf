# BicTerm Coder dev-deployment fixture template (pushed as "bicterm-host" by
# scripts/coder-dev-up.sh against the native loopback dev server on
# 127.0.0.1:7080; NO Docker anywhere).
#
# A single coder_agent named "main" runs natively on the macOS host
# (darwin/arm64 via data.coder_provisioner). The null_resource's local-exec
# writes a per-workspace agent start script embedding the agent token into
# Fixtures/run/coder-dev/agents/; the up script then executes that script to
# connect the host agent. Referencing coder_agent.main.token inside the
# null_resource also associates the agent with that terraform resource.
#
# The /Users/richard/code/BicTerm prefix is a placeholder: coder-dev-up.sh
# rewrites it to the current checkout when materializing the runtime copy
# under Fixtures/run/coder-dev/template/ (same convention as Fixtures/sshd).

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.18"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_provisioner" "me" {}

resource "coder_agent" "main" {
  os   = data.coder_provisioner.me.os
  arch = data.coder_provisioner.me.arch
}

resource "null_resource" "agent_start_script" {
  triggers = {
    workspace_id = data.coder_workspace.me.id
    agent_token  = coder_agent.main.token
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      AGENTS_DIR='/Users/richard/code/BicTerm/Fixtures/run/coder-dev/agents'
      SCRIPT="$AGENTS_DIR/${data.coder_workspace.me.name}.sh"
      mkdir -p "$AGENTS_DIR"
      {
        printf '#!/bin/bash\n'
        printf 'set -euo pipefail\n'
        printf 'export CODER_AGENT_URL="%s"\n' '${data.coder_workspace.me.access_url}'
        printf 'export CODER_AGENT_TOKEN="%s"\n' '${coder_agent.main.token}'
        printf 'export TMPDIR="%s"\n' '/Users/richard/code/BicTerm/Fixtures/run/coder-dev/tmp'
        printf 'exec "%s" agent\n' '/Users/richard/code/BicTerm/Fixtures/run/coder-bin/coder'
      } > "$SCRIPT"
      chmod 700 "$SCRIPT"
    EOT
  }
}
