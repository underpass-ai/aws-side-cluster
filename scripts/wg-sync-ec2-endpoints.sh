#!/usr/bin/env bash
set -euo pipefail

PROJECT_TAG="${PROJECT_TAG:-aws-side-cluster}"
ROLE_TAG="${ROLE_TAG:-worker}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-south-2}}"
WG_INTERFACE="${WG_INTERFACE:-aws-workers}"
WG_PORT="${WG_PORT:-51820}"
SECRETS_DIR="${SECRETS_DIR:-.secrets}"

rows="$(aws --region "$AWS_REGION" ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=tag:Role,Values=$ROLE_TAG" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`aws-side:index`]|[0].Value,PublicIpAddress,InstanceId]' \
  --output text | sort -n)"

if [[ -z "$rows" ]]; then
  echo "No running EC2 workers found for Project=$PROJECT_TAG Role=$ROLE_TAG"
  exit 0
fi

while read -r index public_ip instance_id; do
  [[ -z "${index:-}" || "$public_ip" == "None" ]] && continue
  key_file="$SECRETS_DIR/worker-$(printf "%02d" "$index").pub"
  if [[ ! -f "$key_file" ]]; then
    echo "Missing public key file for worker index $index: $key_file" >&2
    exit 1
  fi

  peer_public_key="$(cat "$key_file")"
  echo "Setting $WG_INTERFACE peer worker-$index ($instance_id) endpoint to $public_ip:$WG_PORT"
  sudo wg set "$WG_INTERFACE" peer "$peer_public_key" endpoint "$public_ip:$WG_PORT" persistent-keepalive 25
done <<< "$rows"

sudo wg show "$WG_INTERFACE"
