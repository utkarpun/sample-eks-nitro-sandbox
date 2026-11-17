#!/usr/bin/env bash
# Prove Bifrost both ways. Each check prints PASS or FAIL; raw output is kept in
# LOG_DIR. One model call in total (T-B0).
#
#   BQ-3   Bifrost is Ready with its ApplicationNetworkPolicy present (NC-B5 shows it enforced)
#   CALLER a pod with Bifrost's ServiceAccount is Bifrost's role; a pod with another one gets no role
#   IAM    Bifrost's role may call the one profile, and a model only through it
#   NC-B2  a request with no key, or a wrong key, is refused 401; the agent's key gets past
#          auth and is refused a model outside its list
#   T-B0   the agent's key gets a model answer through /anthropic
#   COST   Bifrost priced that call from pricing/ (bifrost_cost_total above 0)
#   LOGS   nothing under /app/data holds the T-B0 prompt
#   NC-B7  an admin write with no login, or a wrong one, is refused 401, and nothing changed
#   NC-B5  an agent-labelled pod in the agent namespace reaches Bifrost on 8080; a pod
#          without the label there, and an agent-labelled pod in another namespace, do not
#   T-B2   a new pod keeps the state in Postgres (the key's token count), config.json
#          wins (a key made only in the database is gone), and with 0 replicas
#          nothing answers, with 1 it answers again
source "$(dirname "$0")/lib.sh" || exit 1
set +e
require_runtime_class
resolve_account
LOG_DIR="${LOG_DIR:-$SAMPLE_DIR/../../../tmp/bifrost}"; mkdir -p "$LOG_DIR"
# The model the instance was applied with, so the test calls what Bifrost allows.
MODEL="$(kb get bifrostbackend bifrost -o jsonpath='{.spec.modelID}')"
[[ -n "$MODEL" ]] || die "could not read the model from BifrostBackend bifrost; run ./bifrost/apply.sh first"
OTHER_MODEL="us.anthropic.claude-haiku-4-5-20251001-v1:0"   # not in the key's allow-list
PROBE_IMAGE="docker.io/maximhq/bifrost:v2.5.1@sha256:5ec9873acaf1687556b6e4dd854b92b539d9debf87a5a683b66338648b84d3c8"
AWSCLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.40.3@sha256:33a16c53ea442e918b58df67301ad76a8fb57082c39f7e78753b898c3f3e87c2"
PROMPT='Reply with the single word: ok'
PORT=18580; B="http://127.0.0.1:$PORT"
PASSES=0; FAILS=0
# The sample's scripts/test.sh has its own verdict(); common.sh has none to share.
verdict() { if [[ $2 -eq 0 ]]; then echo "$1 PASS: $3"; PASSES=$((PASSES+1)); else echo "$1 FAIL: $3"; FAILS=$((FAILS+1)); fi; }

# Secrets go to curl through files in a private directory, never the command line.
work="$(mktemp -d)"; chmod 700 "$work"; PF=""
cleanup() { [[ -n "$PF" ]] && kill "$PF" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
sec() { kb get secret "$1" -o jsonpath="{.data.$2}" | python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode())'; }
printf 'user = "%s:%s"\n' "$(sec bifrost-admin username)" "$(sec bifrost-admin password)" > "$work/admin.curl"
printf 'user = "%s:%s"\n' "$(sec bifrost-admin username)" "$(openssl rand -hex 24)" > "$work/wrong-admin.curl"
printf 'x-api-key: %s\n' "$(sec bifrost-agent-key key)" > "$work/vk.hdr"
printf 'x-api-key: sk-bf-%s\n' "$(openssl rand -hex 24)" > "$work/wrong.hdr"
body() { printf '{"model":"bedrock/%s","max_tokens":%s,"messages":[{"role":"user","content":"%s"}]}' "$1" "$2" "$3"; }
msg() {  # <header file or -> <body>: prints the HTTP code, keeps the body in $work/out
  local h=(); [[ "$1" != - ]] && h=(-H "@$1")
  curl -s -m 60 -o "$work/out" -w '%{http_code}' -X POST "$B/anthropic/v1/messages" \
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' "${h[@]}" -d "$2"
}
admin() { curl -s -m 20 -K "$work/admin.curl" "$@"; }
vks() { admin "$B/api/governance/virtual-keys" | python3 -c 'import json,sys; v=json.load(sys.stdin).get("virtual_keys",[]); print(" ".join(sorted(x.get("name","") for x in v)))'; }
usage() { admin "$B/api/governance/virtual-keys" | python3 -c '
import json,sys
for x in json.load(sys.stdin).get("virtual_keys",[]):
    if x.get("name")=="agent": print((x.get("rate_limit") or {}).get("token_current_usage","none"))'; }
pf_start() {
  kb port-forward svc/bifrost "$PORT:8080" >"$LOG_DIR/port-forward.log" 2>&1 & PF=$!
  for _ in $(seq 20); do curl -s -m 2 -o /dev/null "$B/health" && return 0; sleep 1; done; return 1
}
pf_stop() { [[ -n "$PF" ]] && kill "$PF" 2>/dev/null; wait "$PF" 2>/dev/null; PF=""; }
pod_name() { kb get pod -l app.kubernetes.io/name=bifrost -o jsonpath='{.items[0].metadata.name}'; }
probe() {  # <namespace> <pod name> <labels json>: prints REACHED or REFUSED from that namespace
  local ns="$1" n="$2"
  kc_cluster -n "$ns" delete pod "$n" --ignore-not-found --wait >/dev/null 2>&1
  kc_cluster -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $n, labels: $3 }
spec:
  runtimeClassName: isolated-sandbox
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: $PROBE_IMAGE
      command: [sh, -c, "r=REFUSED; for i in 1 2 3; do wget -q -T 5 -O /dev/null http://bifrost.$BIFROST_NAMESPACE.svc.cluster.local:8080/health && { r=REACHED; break; }; sleep 3; done; echo \$r > /dev/termination-log"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
EOF
  kc_cluster -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$n" --timeout=300s >/dev/null 2>&1
  # The result comes back in the pod status, so no kubelet log read is needed.
  kc_cluster -n "$ns" get pod "$n" -o jsonpath='{.status.containerStatuses[0].state.terminated.message}'
  kc_cluster -n "$ns" delete pod "$n" --ignore-not-found >/dev/null 2>&1
}
caller() {  # <pod name> <ServiceAccount>: the pod's caller ARN, or the CLI's error, in LOG_DIR/<pod>.log
  kb delete pod "$1" --ignore-not-found --wait >/dev/null 2>&1
  kb apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $1 }
spec:
  serviceAccountName: $2
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: caller
      image: $AWSCLI_IMAGE
      args: [sts, get-caller-identity, --query, Arn, --output, text]
      # Off in this pod only, so the CLI cannot fall back to the node's role.
      env: [ { name: AWS_EC2_METADATA_DISABLED, value: "true" }, { name: HOME, value: /tmp } ]
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
EOF
  kb wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" --timeout=300s >/dev/null 2>&1 \
    || kb wait --for=jsonpath='{.status.phase}'=Failed "pod/$1" --timeout=10s >/dev/null 2>&1
  kb logs "$1" > "$LOG_DIR/$1.log" 2>&1
  kb delete pod "$1" --ignore-not-found >/dev/null 2>&1
}

# BQ-3
r="$(kb get deploy bifrost -o jsonpath='{.status.readyReplicas}')"
kb get applicationnetworkpolicy bifrost -o name > "$LOG_DIR/BQ-3.log" 2>&1; np=$?
verdict BQ-3 $([[ "$r" == 1 && $np -eq 0 ]]; echo $?) "ready replicas ${r:-0} with ApplicationNetworkPolicy bifrost present"

# CALLER
caller bifrost-caller bifrost; caller bifrost-caller-other default
/usr/bin/grep -q ":assumed-role/$BF_PREFIX-bifrost/" "$LOG_DIR/bifrost-caller.log"; c1=$?
/usr/bin/grep -q ":assumed-role/" "$LOG_DIR/bifrost-caller-other.log"; c2=$?
verdict CALLER $([[ $c1 -eq 0 && $c2 -ne 0 ]]; echo $?) "bifrost ServiceAccount: $(tail -1 "$LOG_DIR/bifrost-caller.log" | sed -E 's/[0-9]{12}/<ACCOUNT_ID>/'); default ServiceAccount: $(tail -1 "$LOG_DIR/bifrost-caller-other.log" | sed -E 's/[0-9]{12}/<ACCOUNT_ID>/')"

# IAM: the role's own policy, simulated; no call is made.
prof="arn:aws:bedrock:$AWS_REGION:$ACCOUNT_ID:inference-profile/$MODEL"
fm="arn:aws:bedrock:$AWS_REGION::foundation-model/${MODEL#*.}"
sim() { aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::$ACCOUNT_ID:role/$BF_PREFIX-bifrost" \
  --action-names bedrock:InvokeModel --resource-arns "$1" "${@:2}" --query 'EvaluationResults[0].EvalDecision' --output text; }
a="$(sim "$prof")"; b="$(sim "$fm")"
c="$(sim "$fm" --context-entries "ContextKeyName=bedrock:InferenceProfileArn,ContextKeyValues=$prof,ContextKeyType=string")"
echo "profile $a; model alone $b; model through the profile $c" > "$LOG_DIR/IAM.log"
verdict IAM $([[ "$a" == allowed && "$b" == implicitDeny && "$c" == allowed ]]; echo $?) "$(cat "$LOG_DIR/IAM.log")"

pf_start || { echo "error: could not reach Bifrost through port-forward" >&2; exit 1; }

# NC-B2, with the model outside the allow-list, so a broken auth check makes no model call.
n1="$(msg - "$(body "$OTHER_MODEL" 8 hi)")"; n2="$(msg "$work/wrong.hdr" "$(body "$OTHER_MODEL" 8 hi)")"
n3="$(msg "$work/vk.hdr" "$(body "$OTHER_MODEL" 8 hi)")"; cp "$work/out" "$LOG_DIR/NC-B2-control.json"
/usr/bin/grep -q "not allowed for virtual key 'agent'" "$LOG_DIR/NC-B2-control.json"; nb=$?
verdict NC-B2 $([[ "$n1" == 401 && "$n2" == 401 && "$n3" == 403 && $nb -eq 0 ]]; echo $?) "no key $n1, wrong key $n2; the agent's key on a model outside its list $n3, body names the key's model list: $([[ $nb -eq 0 ]] && echo yes || echo no)"

# T-B0: the one model call.
t="$(msg "$work/vk.hdr" "$(body "$MODEL" 8 "$PROMPT")")"; cp "$work/out" "$LOG_DIR/T-B0.json"
ans="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("".join(c.get("text","") for c in d.get("content",[])).strip())' "$LOG_DIR/T-B0.json" 2>/dev/null)"
verdict T-B0 $([[ "$t" == 200 && -n "$ans" ]]; echo $?) "HTTP $t, answer '$ans'"

# COST: the telemetry plugin's counter of what Bifrost priced, from pricing/pricing.json.
admin "$B/metrics" > "$LOG_DIR/COST.log" 2>&1
cost="$(python3 -c '
import sys
print(sum(float(l.rsplit(" ", 1)[1]) for l in open(sys.argv[1]) if l.startswith("bifrost_cost_total")))' "$LOG_DIR/COST.log" 2>/dev/null)"
verdict COST $(python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "${cost:-0}" 2>/dev/null; echo $?) "bifrost_cost_total ${cost:-none} USD"

# LOGS: grep exits 1 when no file holds the prompt, 0 when one does, 2 on an error.
sleep 12   # any store write happens in the background
kb exec deploy/bifrost -- grep -rl "$PROMPT" /app/data > "$LOG_DIR/LOGS.log" 2>&1; g=$?
kb exec deploy/bifrost -- ls -la /app/data >> "$LOG_DIR/LOGS.log" 2>&1
verdict LOGS $([[ $g -eq 1 ]]; echo $?) "grep for the T-B0 prompt under /app/data exited $g (1: no file holds it)"

# NC-B7
before="$(vks)"
w1="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$B/api/governance/virtual-keys" -H 'content-type: application/json' -d '{"name":"nc-b7","is_active":true}')"
w2="$(curl -s -m 20 -K "$work/wrong-admin.curl" -o /dev/null -w '%{http_code}' -X POST "$B/api/governance/virtual-keys" -H 'content-type: application/json' -d '{"name":"nc-b7","is_active":true}')"
after="$(vks)"
verdict NC-B7 $([[ "$w1" == 401 && "$w2" == 401 && -n "$before" && "$before" == "$after" ]]; echo $?) "write without login $w1, with a wrong login $w2; keys before '$before', after '$after'"

# NC-B5
p1="$(probe "$AGENT_NAMESPACE" bifrost-probe-agent '{ app.kubernetes.io/name: agent }')"
p2="$(probe "$AGENT_NAMESPACE" bifrost-probe-other '{ app.kubernetes.io/name: other }')"
p3="$(probe "$BIFROST_NAMESPACE" bifrost-probe-agent '{ app.kubernetes.io/name: agent }')"
verdict NC-B5 $([[ "$p1" == REACHED && "$p2" == REFUSED && "$p3" == REFUSED ]]; echo $?) "agent-labelled pod $p1, other pod $p2; agent-labelled pod in $BIFROST_NAMESPACE $p3"

# T-B2
c=$(admin -o /dev/null -w '%{http_code}' -X POST "$B/api/governance/virtual-keys" -H 'content-type: application/json' -d '{"name":"db-only","is_active":true}')
sleep 12   # the usage counters reach the store every 10 s
u1="$(usage)"; k1="$(vks)"; old="$(pod_name)"
kb get pod "$old" -o wide > "$LOG_DIR/T-B2-pods.log" 2>&1
pf_stop; kb delete pod "$old" --wait >/dev/null
kb rollout status deploy/bifrost --timeout=300s >/dev/null; new="$(pod_name)"
pf_start; u2="$(usage)"; k2="$(vks)"
s="$(msg "$work/vk.hdr" "$(body "$OTHER_MODEL" 8 hi)")"
kb get pod "$new" -o wide --no-headers >> "$LOG_DIR/T-B2-pods.log" 2>&1
echo "db-only create $c; count $u1 -> $u2; keys '$k1' -> '$k2'; pod $old -> $new; key check $s" > "$LOG_DIR/T-B2.log"
pf_stop; kb scale deploy/bifrost --replicas=0 >/dev/null
kb wait --for=delete pod/"$new" --timeout=120s >/dev/null 2>&1
z="$(probe "$AGENT_NAMESPACE" bifrost-probe-agent '{ app.kubernetes.io/name: agent }')"
kb scale deploy/bifrost --replicas=1 >/dev/null
kb rollout status deploy/bifrost --timeout=300s >/dev/null
o="$(probe "$AGENT_NAMESPACE" bifrost-probe-agent '{ app.kubernetes.io/name: agent }')"
echo "replicas 0: $z; replicas 1: $o" >> "$LOG_DIR/T-B2.log"
verdict T-B2 $([[ "$c" == 200 && "$old" != "$new" && "$u1" =~ ^[1-9] && "$u2" == "$u1" && "$k1" == *db-only* && "$k2" != *db-only* && "$s" == 403 && "$z" == REFUSED && "$o" == REACHED ]]; echo $?) "$(tr '\n' ' ' < "$LOG_DIR/T-B2.log")"

echo "$PASSES passed, $FAILS failed"
[[ $FAILS -eq 0 ]]
