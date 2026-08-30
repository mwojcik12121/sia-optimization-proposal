#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/sia-lab/controls/common.sh
source /opt/sia-lab/controls/actions.sh
source /opt/sia-lab/controls/info.sh
source /opt/sia-lab/controls/network.sh

info_assert_height 200
sleep 60
network_partition_all
sleep 20
network_heal_all
action_connect_peer node07 >/dev/null 2>&1 || true
sleep 90
action_pause_primary_daemon_for 15
sleep 115
# Final uninterrupted recovery period.
sleep 60
info_wait_for_height 201 300
info_assert_height 201
info_wait_for_height 202 600
info_assert_height 202
