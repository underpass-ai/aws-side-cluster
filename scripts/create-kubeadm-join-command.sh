#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

join_command="$(kubeadm token create --print-join-command)"
join_endpoint="${KUBEADM_JOIN_ENDPOINT:-}"

if [[ -n "$join_endpoint" ]]; then
  join_command="$(awk -v endpoint="$join_endpoint" '{
    for (i = 1; i <= NF; i++) {
      if ($i == "join") {
        $(i + 1) = endpoint
        break
      }
    }
    print
  }' <<< "$join_command")"
fi

printf '%s\n' "$join_command"
