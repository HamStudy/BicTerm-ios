terraform {
  required_providers {
    coder = { source = "coder/coder", version = "~> 2.18" }
    null  = { source = "hashicorp/null", version = "~> 3.2" }
  }
}

data "coder_workspace" "me" {}
data "coder_provisioner" "me" {}

data "coder_parameter" "multi_agent" {
  name    = "multi_agent"
  type    = "bool"
  default = false
  mutable = true
}

data "coder_parameter" "start_blocks_login" {
  name    = "start_blocks_login"
  type    = "bool"
  default = true
  mutable = true
}

data "coder_parameter" "script_mode" {
  name    = "script_mode"
  type    = "string"
  default = "normal"
  mutable = true
  option {
    name  = "Normal"
    value = "normal"
  }
  option {
    name  = "Hold until released"
    value = "hold"
  }
  option {
    name  = "Fail"
    value = "error"
  }
  option {
    name  = "Timeout"
    value = "timeout"
  }
}

locals {
  root = "/Users/richard/code/BicTerm/Fixtures/run/coder-acceptance"
  base = "${local.root}/${data.coder_workspace.me.name}"
  write_script = <<-EOT
    set -euo pipefail
    umask 077
    mkdir -p "$G12_BASE/home" "$G12_BASE/work" "$G12_BASE/tmp"
    {
      printf '#!/bin/bash\nset -euo pipefail\n'
      printf 'export CODER_AGENT_URL=%q\n' "$G12_URL"
      printf 'export CODER_AGENT_TOKEN=%q\n' "$G12_TOKEN"
      printf 'export HOME=%q ZDOTDIR=%q TMPDIR=%q\n' "$G12_BASE/home" "$G12_BASE/home" "$G12_BASE/tmp"
      printf 'exec /Users/richard/code/BicTerm/Fixtures/run/coder-bin/coder agent\n'
    } > "$G12_BASE/$G12_NAME.sh.tmp"
    chmod 700 "$G12_BASE/$G12_NAME.sh.tmp"
    mv "$G12_BASE/$G12_NAME.sh.tmp" "$G12_BASE/$G12_NAME.sh"
  EOT
}

resource "coder_agent" "main" {
  count = data.coder_workspace.me.start_count
  os    = data.coder_provisioner.me.os
  arch  = data.coder_provisioner.me.arch
  dir   = "${local.base}/work"
  env = {
    HOME                     = "${local.base}/home"
    ZDOTDIR                  = "${local.base}/home"
    BICTERM_ACCEPTANCE_AGENT  = "main"
    BICTERM_ACCEPTANCE_SPACE  = data.coder_workspace.me.name
  }
}

resource "coder_agent" "sidecar" {
  count = tobool(data.coder_parameter.multi_agent.value) ? data.coder_workspace.me.start_count : 0
  os    = data.coder_provisioner.me.os
  arch  = data.coder_provisioner.me.arch
  dir   = "${local.base}/work"
  env = {
    HOME                    = "${local.base}/home"
    ZDOTDIR                 = "${local.base}/home"
    BICTERM_ACCEPTANCE_AGENT = "sidecar"
    BICTERM_ACCEPTANCE_SPACE = data.coder_workspace.me.name
  }
}

resource "coder_script" "startup" {
  count              = data.coder_workspace.me.start_count
  agent_id           = coder_agent.main[0].id
  display_name       = "Acceptance startup"
  run_on_start       = true
  start_blocks_login = tobool(data.coder_parameter.start_blocks_login.value)
  timeout            = data.coder_parameter.script_mode.value == "timeout" ? 1 : 600
  log_path           = "${local.base}/startup.log"
  script = <<-EOT
    set -eu
    printf 'entered\n' > '${local.base}/startup-entered'
    case '${data.coder_parameter.script_mode.value}' in
      hold)
        while [ ! -f '${local.base}/release-startup' ]; do sleep 0.1; done
        ;;
      error)
        printf 'g12 deliberate startup failure\n' >&2
        exit 7
        ;;
      timeout)
        sleep 60
        ;;
      normal) : ;;
      *) exit 8 ;;
    esac
    printf 'completed\n' > '${local.base}/startup-completed'
  EOT
}

resource "null_resource" "main_script" {
  count    = data.coder_workspace.me.start_count
  triggers = { agent_id = coder_agent.main[0].id }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      G12_TOKEN = coder_agent.main[0].token
      G12_URL   = data.coder_workspace.me.access_url
      G12_BASE  = local.base
      G12_NAME  = "main"
    }
    command = local.write_script
  }
}

resource "null_resource" "sidecar_script" {
  count    = tobool(data.coder_parameter.multi_agent.value) ? data.coder_workspace.me.start_count : 0
  triggers = { agent_id = coder_agent.sidecar[0].id }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      G12_TOKEN = coder_agent.sidecar[0].token
      G12_URL   = data.coder_workspace.me.access_url
      G12_BASE  = local.base
      G12_NAME  = "sidecar"
    }
    command = local.write_script
  }
}
