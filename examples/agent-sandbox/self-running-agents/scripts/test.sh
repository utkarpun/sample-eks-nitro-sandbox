#!/usr/bin/env bash
# Check the sample both ways: one agent run that works end to end, and one
# refusal for each thing that is meant to refuse. Each check reads PASS or FAIL
# from the run's own output, and the raw output is kept in LOG_DIR.
#
#   T    the agent's get_time call was answered without error, and its final answer has the time-in-utc: form with the time the tool returned;
#        the agent has no Bedrock permission and no bedrock-runtime egress, so a pass also shows its model calls went through Bifrost (T-B1)
#   T2   outside the model, the gateway lists only get_time for the agent's role and answers it
#   NC1  in the T run, the egress gate's connections to a host the egress rule does not name failed
#   NC2  a call to get_host_info, which the Cedar policy does not permit, is refused by the gateway
#   NC4  the egress gate stops a run when its canary host is reachable
#   NC-B1 the agent cannot call Bedrock itself: its role may not invoke the model (Bifrost's role, the control, may),
#        and a run whose canary is bedrock-runtime finds it unreachable
#   NC3  admission refuses a pod that automounts the service-account token, and accepts one that does not
source "$(dirname "$0")/common.sh" || exit 1
load_status   # the namespace (NC3) and Region (NC4), from the instances
set +e
LOG_DIR="${LOG_DIR:-$SAMPLE_DIR/../../../tmp/$SAMPLE}"
mkdir -p "$LOG_DIR"
PASSES=0; FAILS=0
verdict() { if [[ $2 -eq 0 ]]; then echo "$1 PASS: $3"; PASSES=$((PASSES+1)); else echo "$1 FAIL: $3"; FAILS=$((FAILS+1)); fi; }

# T: a get_time call was answered without error, and the final answer has the time-in-utc: form with the time it returned.
"$HERE/run.sh" agent > "$LOG_DIR/T.log" 2>&1; rc=$?
python3 - "$LOG_DIR/T.log" <<'PY' > "$LOG_DIR/T.check" 2>&1
import json, sys
calls, results, final, ids, times, bad = [], [], "", set(), [], False
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        m = json.loads(line)
    except ValueError:
        continue
    for c in (m.get("message") or {}).get("content") or []:
        if isinstance(c, dict) and c.get("type") == "tool_use":
            calls.append(c.get("name"))
            if (c.get("name") or "").endswith("clock___get_time"):
                ids.add(c.get("id"))
        if isinstance(c, dict) and c.get("type") == "tool_result":
            results.append(json.dumps(c.get("content"))[:300])
            if c.get("tool_use_id") in ids:
                bad = bad or bool(c.get("is_error"))
                for part in c.get("content") if isinstance(c.get("content"), list) else []:
                    try:
                        times.append(json.loads(part.get("text", "")).get("time"))
                    except (ValueError, AttributeError):
                        pass
    if m.get("type") == "result":
        final = m.get("result") or ""
        bad = bad or bool(m.get("is_error"))
print("tool calls:", calls)
print("tool results:", results)
print("final:", final)
ok = not bad and bool(times) and times[-1] is not None and f"time-in-utc: {times[-1]}" in final
sys.exit(0 if ok else 1)
PY
c=$?; [[ $rc -ne 0 ]] && c=1
verdict T $c "$(tr '\n' ' ' < "$LOG_DIR/T.check")"

# T2 and NC2 from one run outside the model.
"$HERE/run.sh" tools "${TARGET}___get_time" "${TARGET}___get_host_info" > "$LOG_DIR/tools.log" 2>&1
python3 - "$LOG_DIR/tools.log" "$TARGET" <<'PY' > "$LOG_DIR/tools.check" 2>&1
import json, re, sys
text, target = open(sys.argv[1]).read(), sys.argv[2]
m = re.search(r'^\{$.*?^\}$', text, re.S | re.M)
doc = json.loads(m.group(0)) if m else {"listed": [], "calls": []}
calls = {c["tool"].split("___")[-1]: c for c in doc.get("calls", [])}
t = calls.get("get_time", {}); d = calls.get("get_host_info", {})
listed_only = [n for n in doc.get("listed", []) if n.startswith(target + "___")] == [target + "___get_time"]
t2 = listed_only and bool(t) and not t["isError"] and '"time"' in t["text"]
nc2 = bool(d) and d["isError"] and "Tool Execution Denied" in d["text"] and "policy enforcement" in d["text"]
print(f"T2 {int(not t2)} listed={doc.get('listed', [])} get_time={t.get('text','')[:160]}")
print(f"NC2 {int(not nc2)} get_host_info isError={d.get('isError')} text={d.get('text','')[:200]}")
PY
while read -r name code rest; do verdict "$name" "$code" "$rest"; done < <(grep -E '^(T2|NC2) ' "$LOG_DIR/tools.check")
grep -qE '^T2 ' "$LOG_DIR/tools.check" || verdict T2 1 "no tool list in the run's output: $(tail -3 "$LOG_DIR/tools.log" | tr '\n' ' ')"

# NC1: a host the egress rule does not name, read from the T run's egress gate line.
line="$(grep -E "^sra: egress gate: ${EGRESS_CANARY:-example.com}:443 failed to connect 3 times" "$LOG_DIR/T.log")"
verdict NC1 $? "${line:-no gate line in T.log}"

# NC4: the egress gate stops a run when its canary answers. Pointed at a host the rule does allow (the
# run bucket's), it never sees a connection fail, so the run must stop before the tool call it was given.
EGRESS_CANARY="$RUN_BUCKET.s3.$AWS_REGION.amazonaws.com" "$HERE/run.sh" tools "${TARGET}___get_time" > "$LOG_DIR/NC4.log" 2>&1; nrc=$?
line="$(grep -E '^sra: egress gate: ' "$LOG_DIR/NC4.log" | tr '\n' ' ')"
[[ $nrc -ne 0 ]] && grep -q 'still reachable' "$LOG_DIR/NC4.log" && ! grep -q '"listed"' "$LOG_DIR/NC4.log"
verdict NC4 $? "${line:-no gate line} run rc=$nrc"

# NC-B1: the agent cannot reach Bedrock without Bifrost, at two layers. IAM, which holds on any node: the
# agent role may not invoke the model's inference profile, and Bifrost's role may (the control). Network:
# a run whose canary is bedrock-runtime goes on, since the egress rule no longer names it; NC4 is its
# control. On EKS Auto Mode an allow learned for one pod is shared with every pod on its node, so on a node
# that also runs Bifrost the network leg can read FAIL while the IAM leg still holds.
resolve_account
BIFROST_ROLE=bfx-bifrost   # bifrost/rgd.yaml names it ${prefix}-bifrost, prefix bfx (bifrost/lib.sh)
sim() {
  aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::$ACCOUNT_ID:role/$1" \
    --action-names bedrock:InvokeModel bedrock:InvokeModelWithResponseStream \
    --resource-arns "arn:aws:bedrock:$AWS_REGION:$ACCOUNT_ID:inference-profile/$BEDROCK_MODEL_ID" \
    --query 'EvaluationResults[].EvalDecision' --output text 2>&1 | tr '\t\n' '  ' | sed 's/ *$//'
}
a="$(sim "$PREFIX-agent")"; b="$(sim "$BIFROST_ROLE")"
EGRESS_CANARY="bedrock-runtime.$AWS_REGION.amazonaws.com" "$HERE/run.sh" tools "${TARGET}___get_time" > "$LOG_DIR/NC-B1.log" 2>&1; brc=$?
line="$(grep -E '^sra: egress gate: ' "$LOG_DIR/NC-B1.log" | tr '\n' ' ')"
printf 'agent role: %s\nbifrost role: %s\n' "$a" "$b" >> "$LOG_DIR/NC-B1.log"
r=1; [[ "$a" == "implicitDeny implicitDeny" && "$b" == "allowed allowed" && $brc -eq 0 && "$line" == *"failed to connect 3 times"* ]] && r=0
verdict NC-B1 $r "agent role: $a; $BIFROST_ROLE role: $b; ${line:-no gate line} run rc=$brc"

# NC3: server-side dry runs, so nothing is created. The positive control is the
# same pod with the token turned off.
pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: { name: admission-check, namespace: $NAMESPACE }
spec:
  runtimeClassName: isolated-sandbox
  automountServiceAccountToken: $1
  containers: [ { name: c, image: public.ecr.aws/docker/library/busybox:stable } ]
EOF
}
pod true > "$LOG_DIR/nc3-bad.yaml"; pod false > "$LOG_DIR/nc3-good.yaml"
bad="$(kc create --dry-run=server -f "$LOG_DIR/nc3-bad.yaml" 2>&1)"; brc=$?
good="$(kc create --dry-run=server -f "$LOG_DIR/nc3-good.yaml" 2>&1)"; grc=$?
printf '%s\n---\n%s\n' "$bad" "$good" > "$LOG_DIR/NC3.log"
[[ $brc -ne 0 && "$bad" == *"automountServiceAccountToken: false"* && $grc -eq 0 ]]
verdict NC3 $? "token on: $(tr '\n' ' ' <<<"$bad" | cut -c1-200) | token off: $good"

echo
echo "checks: $PASSES PASS, $FAILS FAIL (logs in ${LOG_DIR#"$SAMPLE_DIR/../../../"})"
[[ $FAILS -eq 0 ]]
