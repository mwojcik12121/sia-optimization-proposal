#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/sia-lab/controls/common.sh
source /opt/sia-lab/controls/actions.sh
source /opt/sia-lab/controls/info.sh
source /opt/sia-lab/controls/network.sh

info_assert_height 200
for _ in $(seq 1 12); do
  network_partition_all
  sleep 20
  network_heal_all
  action_connect_peer node07 >/dev/null 2>&1 || true
  sleep 5
done
network_heal_all
# A clean recovery window lets hostd reconnect and catch up before completion.
sleep 60
info_wait_for_height 201 300
info_assert_height 201
info_wait_for_height 202 600
info_assert_height 202
