#!/usr/bin/env bash
set -Eeuo pipefail
source /opt/sia-lab/controls/common.sh
source /opt/sia-lab/controls/actions.sh
source /opt/sia-lab/controls/info.sh
source /opt/sia-lab/controls/network.sh

info_assert_height 200
info_wait_for_height 201 300
info_assert_height 201
# Waiting for block 202 is the node's bounded idle behavior and completion barrier.
info_wait_for_height 202 1200
info_assert_height 202
