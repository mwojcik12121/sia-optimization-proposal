#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/sia-lab/controls/common.sh
source /opt/sia-lab/controls/actions.sh
source /opt/sia-lab/controls/info.sh
source /opt/sia-lab/controls/network.sh

info_assert_height 200
for _ in $(seq 1 7); do
  action_pause_primary_daemon_for 30
  sleep 10
done
action_pause_primary_daemon_for 20
# Final uninterrupted recovery period.
sleep 60
info_wait_for_height 201 300
info_assert_height 201
info_wait_for_height 202 600
info_assert_height 202
