#!/usr/bin/env bash
# Start one agent run and stream its output as it happens.
#
#   ./scripts/run.sh                 the agent: headless Claude Code with agent/prompt.txt
#   ./scripts/run.sh tools <tool...> list the gateway's tools and call each named one
#
# EGRESS_CANARY names the host agent/run.sh's egress gate waits to fail to reach
# (default example.com); it must be a host the egress rule does not name.
#
# Each run is its own Job, created for the run and deleted after it. The logs are
# streamed from the moment the pod starts, because EKS Auto Mode can remove the
# node once the pod has finished, and the logs with it. The run's output is also
# stored in the run bucket under runs/<run id>/ (agent/run.sh).
source "$(dirname "$0")/common.sh" || exit 1
require_commands sha256sum od "$KUBECTL"

MODE="${1:-agent}"; shift || true
PROBE_CALLS=""
case "$MODE" in
  agent) ;;
  tools) PROBE_CALLS="$*" ;;
  *) die "unknown mode '$MODE'; use agent or tools" ;;
esac
[[ "$PROBE_CALLS" =~ ^[A-Za-z0-9_\ ]*$ ]] || die "tool names may hold letters, digits and underscores only"
EGRESS_CANARY="${EGRESS_CANARY:-example.com}"
[[ "$EGRESS_CANARY" =~ ^[A-Za-z0-9.-]+$ ]] || die "EGRESS_CANARY must be a host name"

# Namespace, bucket, image repository, Region and model, from the two instances.
load_status
RUN_ID="$(date -u +%Y%m%dt%H%M%Sz)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
JOB="agent-$MODE-$RUN_ID"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
IMAGE="$(image_uri "$REPOSITORY_URI")" || exit 1
render "$SAMPLE_DIR/deploy/run-job.yaml" -e "s|<JOB_NAME>|$JOB|g" -e "s|<RUN_ID>|$RUN_ID|g" \
  -e "s|<RUN_MODE>|$MODE|g" -e "s|<PROBE_CALLS>|$PROBE_CALLS|g" -e "s|<EGRESS_CANARY>|$EGRESS_CANARY|g" -e "s|<IMAGE>|$IMAGE|g" > "$WORK/job.yaml"

echo "run $RUN_ID: mode $MODE, job $JOB"
kc create -f "$WORK/job.yaml" >/dev/null

# Wait for the pod to start (or fail to), then follow its logs to the end.
deadline=$((SECONDS + 600)); pod=""
while :; do
  pod="$(kc get pods -l "self-running-agents/run=$RUN_ID" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  phase="$(kc get pods -l "self-running-agents/run=$RUN_ID" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  [[ -n "$pod" && "$phase" != "Pending" && -n "$phase" ]] && break
  ((SECONDS >= deadline)) && { kc describe job "$JOB" | tail -20; die "the run's pod did not start within 600 s"; }
  sleep 3
done
kc logs -f "pod/$pod" || true

# The Job's own verdict, not the log's.
for _ in $(seq 1 30); do
  st="$(kc get job "$JOB" -o jsonpath='{.status.succeeded}{"|"}{.status.failed}' 2>/dev/null || echo '|')"
  [[ "$st" != "|" ]] && break
  sleep 2
done
[[ "$st" == "|" ]] && { echo "run $RUN_ID: no verdict after 60 s; job $JOB left in place"; exit 1; }
echo "run $RUN_ID: job succeeded=${st%%|*} failed=${st##*|}"
echo "run output: s3://$RUN_BUCKET/runs/$RUN_ID/"
kc delete job "$JOB" --wait=false >/dev/null
[[ "${st%%|*}" == "1" ]]
