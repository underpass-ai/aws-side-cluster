#!/usr/bin/env bash
set -euo pipefail

PROJECT_TAG="${PROJECT_TAG:-aws-side-cluster}"
ROLE_TAG="${ROLE_TAG:-worker}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

usage() {
  cat <<USAGE
Usage:
  $0 status
  $0 status-tag <tag-key> <tag-value>
  $0 start [count]
  $0 start-tag <tag-key> <tag-value> [count]
  $0 stop [count]
  $0 stop-tag <tag-key> <tag-value> [count]
  $0 scale <desired-running-count>
  $0 scale-tag <tag-key> <tag-value> <desired-running-count>

Environment:
  PROJECT_TAG  default: aws-side-cluster
  ROLE_TAG     default: worker
  AWS_REGION   optional if configured in AWS CLI
USAGE
}

aws_args=()
if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

tag_filters=()

set_tag_filter() {
  local key="$1"
  local value="$2"
  tag_filters=("Name=tag:$key,Values=$value")
}

describe_ids() {
  local states="$1"
  aws "${aws_args[@]}" ec2 describe-instances \
    --filters \
      "Name=tag:Project,Values=$PROJECT_TAG" \
      "Name=tag:Role,Values=$ROLE_TAG" \
      "${tag_filters[@]}" \
      "Name=instance-state-name,Values=$states" \
    --query 'Reservations[].Instances[] | sort_by(@,&LaunchTime)[].InstanceId' \
    --output text
}

count_words() {
  if [[ $# -eq 0 || -z "${1:-}" ]]; then
    echo 0
    return
  fi
  wc -w <<< "$*"
}

start_instances() {
  local count="${1:-1}"
  local ids
  ids="$(describe_ids stopped)"
  if [[ -z "$ids" ]]; then
    echo "No stopped instances found for Project=$PROJECT_TAG Role=$ROLE_TAG"
    return 0
  fi

  local selected
  selected="$(tr ' ' '\n' <<< "$ids" | head -n "$count" | tr '\n' ' ')"
  if [[ -z "$selected" ]]; then
    return 0
  fi

  echo "Starting: $selected"
  aws "${aws_args[@]}" ec2 start-instances --instance-ids $selected >/dev/null
}

stop_instances() {
  local count="${1:-1}"
  local ids
  ids="$(describe_ids running)"
  if [[ -z "$ids" ]]; then
    echo "No running instances found for Project=$PROJECT_TAG Role=$ROLE_TAG"
    return 0
  fi

  local selected
  selected="$(tr ' ' '\n' <<< "$ids" | tail -n "$count" | tr '\n' ' ')"
  if [[ -z "$selected" ]]; then
    return 0
  fi

  echo "Stopping: $selected"
  aws "${aws_args[@]}" ec2 stop-instances --instance-ids $selected >/dev/null
}

scale_instances() {
  local desired="$1"
  if ! [[ "$desired" =~ ^[0-9]+$ ]]; then
    echo "desired-running-count must be a non-negative integer" >&2
    exit 2
  fi

  local active running active_count running_count
  active="$(describe_ids pending,running)"
  running="$(describe_ids running)"
  active_count="$(count_words "$active")"
  running_count="$(count_words "$running")"

  if (( active_count < desired )); then
    start_instances "$((desired - active_count))"
  elif (( running_count > desired )); then
    stop_instances "$((running_count - desired))"
  else
    echo "Pool already at desired capacity: desired=$desired active=$active_count running=$running_count"
  fi
}

status_instances() {
  aws "${aws_args[@]}" ec2 describe-instances \
    --filters \
      "Name=tag:Project,Values=$PROJECT_TAG" \
      "Name=tag:Role,Values=$ROLE_TAG" \
      "${tag_filters[@]}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Index:Tags[?Key==`aws-side:index`]|[0].Value,Id:InstanceId,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,PrivateIp:PrivateIpAddress}' \
    --output table
}

cmd="${1:-}"
case "$cmd" in
  status)
    status_instances
    ;;
  status-tag)
    if [[ $# -ne 3 ]]; then
      usage >&2
      exit 2
    fi
    set_tag_filter "$2" "$3"
    status_instances
    ;;
  start)
    start_instances "${2:-1}"
    ;;
  start-tag)
    if [[ $# -lt 3 || $# -gt 4 ]]; then
      usage >&2
      exit 2
    fi
    set_tag_filter "$2" "$3"
    start_instances "${4:-1}"
    ;;
  stop)
    stop_instances "${2:-1}"
    ;;
  stop-tag)
    if [[ $# -lt 3 || $# -gt 4 ]]; then
      usage >&2
      exit 2
    fi
    set_tag_filter "$2" "$3"
    stop_instances "${4:-1}"
    ;;
  scale)
    if [[ $# -ne 2 ]]; then
      usage >&2
      exit 2
    fi
    scale_instances "$2"
    ;;
  scale-tag)
    if [[ $# -ne 4 ]]; then
      usage >&2
      exit 2
    fi
    set_tag_filter "$2" "$3"
    scale_instances "$4"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
