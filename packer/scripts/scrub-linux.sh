#!/usr/bin/env bash
#
# scrub-linux.sh — final Packer step for the REMnux and OpenSearch AMIs.
# (SIFT has its own scrub-sift.sh, which also removes gateway secrets.)
#
# Removes per-instance identity and Packer's access, and resets cloud-init so
# the launched instance runs its user data. Neither image holds secrets: the
# REMnux token and OpenSearch password are applied at first boot.
#
set -euxo pipefail

rm -f /etc/ssh/ssh_host_*                                          # regenerated per instance
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys # Packer's temporary key
rm -f /root/.bash_history /home/*/.bash_history
apt-get clean
cloud-init clean --logs --machine-id --seed                        # re-run user-data on launch

echo "scrub-linux.sh complete"
