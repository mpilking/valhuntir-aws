###############################################################################
# Checkpoints — what software a deploy runs
#
# Every deploy names one (there is deliberately no default):
#
#   -var checkpoint=<name>   Launch the baked AMIs recorded in
#                            ../checkpoints/<name>.json. Nothing is downloaded
#                            or installed at boot beyond per-instance config, so
#                            upstream drift cannot break the deploy.
#   -var checkpoint=latest   Build every host from a fresh base image with every
#                            component at its newest version. May fail; used to
#                            try out new upstream versions before cutting a new
#                            checkpoint (see ../checkpoints/README.md).
###############################################################################

locals {
  is_latest       = var.checkpoint == "latest"
  checkpoint_path = "${path.module}/../checkpoints/${var.checkpoint}.json"
  checkpoint_raw = (local.is_latest ? null :
  fileexists(local.checkpoint_path) ? jsondecode(file(local.checkpoint_path)) : null)

  # Every version input a host install depends on. In a checkpoint each must be
  # an explicit value; under "latest" each is the literal "latest" and the
  # install scripts resolve it to the newest release at boot.
  # (Same names as the Packer variables in ../packer/variables.pkr.hcl.)
  pin_keys = [
    "ubuntu_ami", "windows_base_ami", "awscli", "cast",
    "sift_saltstack", "sift_mcp", "valhuntir", "opensearch_mcp", "pypi_exclude_newer",
    "remnux_saltstack", "remnux_mcp_server", "nodejs", "docker",
    "wintools_mcp", "choco_git", "choco_python312",
  ]
  pins = { for k in local.pin_keys : k => (
    local.is_latest ? "latest" : try(tostring(local.checkpoint_raw.pins[k]), "")
  ) }
  missing_pins = [for k, v in local.pins : k if v == ""]

  # Baked AMI per host ("" under latest = build from base at boot).
  hosts = ["sift", "remnux", "opensearch", "windows"]
  amis  = { for h in local.hosts : h => local.is_latest ? "" : try(local.checkpoint_raw.amis[h], "") }
  baked = !local.is_latest

  # Install choices that are baked into the AMIs come from the checkpoint; the
  # variables only apply when building from base (latest).
  sift_user   = local.is_latest ? var.sift_user : try(local.checkpoint_raw.build.sift_user, "")
  sift_mode   = local.is_latest ? var.sift_mode : try(local.checkpoint_raw.build.sift_mode, "")
  remnux_user = local.is_latest ? var.remnux_user : try(local.checkpoint_raw.build.remnux_user, "")
  remnux_mode = local.is_latest ? var.remnux_mode : try(local.checkpoint_raw.build.remnux_mode, "")

  # Base images. The bastion is never baked; it runs the checkpoint's Ubuntu.
  ubuntu_ami = local.is_latest ? data.aws_ami.ubuntu[0].id : local.pins.ubuntu_ami
}

# Fails the plan early, with a readable message, on a bad checkpoint.
resource "terraform_data" "checkpoint" {
  input = var.checkpoint

  lifecycle {
    precondition {
      condition     = local.is_latest || local.checkpoint_raw != null
      error_message = "No checkpoint file ${local.checkpoint_path}. Use an existing checkpoints/<name>.json or checkpoint=\"latest\"."
    }
    precondition {
      condition     = local.is_latest || try(local.checkpoint_raw.region, "") == var.region
      error_message = "Checkpoint ${var.checkpoint} was baked in region ${try(local.checkpoint_raw.region, "?")}, but region is ${var.region}. AMIs are regional: copy them, or bake a checkpoint for this region."
    }
    precondition {
      condition     = length(local.missing_pins) == 0
      error_message = "Checkpoint ${var.checkpoint} is missing pins: ${join(", ", local.missing_pins)}."
    }
    precondition {
      condition     = local.is_latest || alltrue([for k in ["sift_user", "sift_mode", "remnux_user", "remnux_mode"] : try(local.checkpoint_raw.build[k], "") != ""])
      error_message = "Checkpoint ${var.checkpoint} is missing build settings (sift_user, sift_mode, remnux_user, remnux_mode)."
    }
  }
}

# Deploying a candidate is how one gets validated, so it's allowed, but say so.
check "checkpoint_status" {
  assert {
    condition     = local.is_latest || try(local.checkpoint_raw.status, "") == "validated"
    error_message = "Checkpoint ${var.checkpoint} has status '${try(local.checkpoint_raw.status, "unknown")}', not 'validated'. Fine for testing it; don't rely on it for casework yet."
  }
}

check "latest_is_unpinned" {
  assert {
    condition     = !local.is_latest
    error_message = "checkpoint=latest: every host installs the newest upstream versions at boot (~1–2 h). This can fail; it is for trying new versions, not for casework."
  }
}
