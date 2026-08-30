#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/sia-lab/controls/common.sh
source /opt/sia-lab/controls/actions.sh
source /opt/sia-lab/controls/info.sh
source /opt/sia-lab/controls/network.sh

info_assert_height 200
sleep 2
# Block 201 opens the bounded observation window.
action_mine_blocks 1
info_wait_for_height 201 60
info_assert_height 201
# The fault pattern and repair observer run for five minutes plus one minute recovery.
sleep 365
# Every participant is still alive; wait for the impaired host to have block 201.
info_wait_for_selected_height 201 600
info_assert_selected_height 201
# Block 202 is the completion signal that releases all idle nodes.
action_mine_blocks 1
info_wait_for_height 202 60
info_assert_height 202
sleep 5
