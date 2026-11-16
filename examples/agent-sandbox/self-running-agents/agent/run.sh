#!/usr/bin/env bash
# One stateless agent run, inside the sandbox. The Job that runs this is created
# for one run and gone after it: everything the run produces is printed to
# standard output, which scripts/run.sh streams out as it happens, and copied to
# the run bucket before the pod exits. Nothing is kept in the pod.
#
# RUN_MODE picks what the pod does:
#   agent     headless Claude Code with the prompt in /cfg/prompt.txt
#   tools     list the gateway's tools and call each name in PROBE_CALLS, outside
#             the model, so a refusal is the gateway's and not the model's choice
#   internet  try one HTTPS request to a host the egress policy does not allow
set -uo pipefail

: "${RUN_ID:?}" "${RUN_MODE:?}" "${RUN_BUCKET:?}" "${AWS_REGION:?}"
OUT=/work/out
mkdir -p "$OUT" "$HOME/.claude"
say() { echo "sra: $*"; }

say "run=$RUN_ID mode=$RUN_MODE start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "kernel=$(uname -r) uid=$(id -u)"
for p in /var/run/secrets/kubernetes.io/serviceaccount "$HOME/.aws"; do
  [[ -e $p ]] && say "credential path present: $p" || say "credential path absent: $p"
done

# Egress gate. A new pod's network policy is not in force the moment the pod
# starts: on EKS Auto Mode the first request of a fresh agent pod reached
# example.com, and the same request about 8 s later was refused. So nothing
# runs until a host the egress rule does not name is refused three times in a
# row, and the run fails closed if that does not happen within 90 s.
/opt/mcp/bin/python - "${EGRESS_CANARY:-example.com}" <<'PY' || { say "egress gate: the egress rule is not in force; stopping"; exit 3; }
import socket, sys, time
host, t0, refused = sys.argv[1], time.time(), 0
while time.time() - t0 < 90:
    try:
        socket.create_connection((host, 443), timeout=2).close()
        refused = 0
    except OSError:
        refused += 1
        if refused == 3:
            print(f"sra: egress gate: {host}:443 refused 3 times in a row after {time.time() - t0:.1f} s")
            sys.exit(0)
    time.sleep(1)
print(f"sra: egress gate: {host}:443 still reachable after 90 s")
sys.exit(1)
PY

# The agent's configuration is baked into the image under /opt/agent, and the
# home directory is an emptyDir, because the root filesystem is read-only.
cp /opt/agent/settings.json "$HOME/.claude/settings.json"
cp /opt/agent/claude.json "$HOME/.claude.json"

rc=0
case "$RUN_MODE" in
  agent)
    say "claude $(claude --version 2>&1)"
    cd /work
    claude -p --output-format stream-json --verbose \
      --setting-sources user --no-session-persistence \
      --strict-mcp-config --mcp-config /cfg/mcp.json \
      --permission-mode dontAsk --max-turns 8 \
      < /cfg/prompt.txt | tee "$OUT/stream.jsonl"
    rc=${PIPESTATUS[0]}
    ;;
  tools)
    # shellcheck disable=SC2086 # PROBE_CALLS is a space-separated list of names
    /opt/mcp/bin/python /opt/agent/mcp_call.py /cfg/mcp.json ${PROBE_CALLS:-} | tee "$OUT/tools.json"
    rc=${PIPESTATUS[0]}
    ;;
  internet)
    /opt/mcp/bin/python - "${PROBE_URL:-https://example.com/}" <<'PY' | tee "$OUT/internet.txt"
import sys, urllib.request
url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=10) as r:
        print(f"internet: {url} answered {r.status}")
except Exception as e:  # any failure to connect is the expected result
    print(f"internet: {url} refused: {type(e).__name__}: {e}")
PY
    rc=${PIPESTATUS[0]}
    ;;
  *) say "unknown RUN_MODE $RUN_MODE"; exit 2 ;;
esac
say "rc=$rc"

# State outside the pod: copy what the run produced to the run bucket, under
# runs/<run id>/. The pod's role may only put objects under runs/.
/opt/mcp/bin/python - "$OUT" "$RUN_BUCKET" "runs/$RUN_ID" <<'PY'
import os, sys, boto3
out, bucket, prefix = sys.argv[1:4]
s3 = boto3.client("s3", region_name=os.environ["AWS_REGION"])
for name in sorted(os.listdir(out)):
    s3.upload_file(os.path.join(out, name), bucket, f"{prefix}/{name}")
    print(f"sra: stored s3://{bucket}/{prefix}/{name}")
PY
up=$?
[[ $up -ne 0 ]] && say "storing the run's output failed (rc=$up)"
say "end=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[[ $rc -ne 0 ]] && exit "$rc"
exit "$up"
