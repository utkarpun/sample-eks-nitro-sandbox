# Self-running agents: a short-lived agent whose tools come only through an AgentCore Gateway

This blueprint runs an agent the way a self-running repository agent would: one headless
Claude Code run per job, in an isolated Nitro sandbox, started for the job and gone after
it, with everything it produced copied out of the pod before it exits. The agent holds no
tool of its own. Its only tools come through an Amazon Bedrock AgentCore Gateway, which
asks a Cedar policy engine about every call, so what the agent may do is decided outside
the sandbox by a policy you can read, not by the agent's own settings.

This is phase A of the blueprint: the tool door. The agent calls Amazon Bedrock directly
for its model, with one inference profile. A later phase puts an in-cluster model gateway
in front of Bedrock.

It needs an EKS Auto Mode cluster with Nitro sandboxes and network policy enforcement on,
as the [prerequisites](../../README.md#prerequisites) and the
[Hello sandbox](../../getting-started/hello-sandbox/README.md) sample set up. Beyond that it
needs Docker with `linux/amd64` builds, the AWS CLI v2 with the `bedrock-agentcore-control`
commands (2.35 or later was used), access to the Bedrock model named in `.env`, and AgentCore
Gateway and AgentCore Policy in your Region (this run used `us-west-2`).

```bash
git clone https://github.com/aws-samples/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/agent-sandbox/self-running-agents
```

## Overview

| Piece | What it is | Where it runs |
|---|---|---|
| The agent run | A Kubernetes Job: Claude Code with `-p`, one prompt, then exit | An isolated Nitro sandbox pod in the sample's namespace |
| The bridge | `mcp-proxy-for-aws-cli`, a stdio MCP server that signs each request with SigV4 | Inside the agent pod, started by Claude Code |
| The tool door | An AgentCore Gateway, MCP protocol, inbound auth `AWS_IAM` | AWS, managed |
| The policy | A Cedar policy engine in `ENFORCE` mode on the gateway, with one `permit` | AWS, managed |
| The tool | A Lambda function with two read-only tools, `get_time` and `get_host_info` | AWS Lambda |
| The run's state | `runs/<run id>/` in a run bucket | Amazon S3 |

A run goes like this:

1. `scripts/run.sh` creates a Job for the run and follows its logs from the moment the pod
   starts.
2. Before anything else the pod waits until its egress rule is in force (the egress gate,
   below).
3. Claude Code starts the bridge, which lists the gateway's tools as the pod's IAM role.
   The gateway lists only the tools the Cedar policy permits that role: `clock___get_time`.
4. The model calls `clock___get_time`. The gateway asks the policy engine, the policy
   permits it, and the gateway invokes the Lambda function.
5. The pod copies the run's stream to the run bucket, exits, and `run.sh` deletes the Job.

### Design

**Identity.** The pod's ServiceAccount maps to one IAM role through EKS Pod Identity. That
role may invoke the one inference profile and the foundation models it routes to, call
`bedrock-agentcore:InvokeGateway` on the one gateway, and put objects under `runs/` in the
run bucket. It holds nothing else. This follows the EKS Best Practices Guide's "Use one IAM
role per application" (`latest/bpg/security/iam.adoc:1078-1084` at
`aws/aws-eks-best-practices` `edc514fac86518b50129401c0cffd1f7981d7ec5`).

**The tool door.** The gateway authenticates the caller by its SigV4 signature, so the
Cedar principal is the pod's role:
`AgentCore::IamEntity::"arn:aws:sts::<ACCOUNT_ID>:assumed-role/<NAME_PREFIX>-agent"`.
The one policy, `policy/allow-get-time.cedar`, permits that principal to call
`clock___get_time` on that gateway. Cedar is default-deny, so `get_host_info` is refused
for the agent, and every tool is refused for any other caller. The gateway's own role may
invoke only the tool function and ask only its own policy engine for decisions.

**No Kubernetes token.** The pod spec sets `automountServiceAccountToken: false`, as the
EKS Best Practices Guide's "Disable auto-mounting of service account tokens" says
(`latest/bpg/security/iam.adoc:1104-1108`, same commit). An isolated Nitro sandbox does get
the token when automount is on, so that setting is the only thing keeping it out. A
`ValidatingAdmissionPolicy` (`deploy/admission.yaml`), built into Kubernetes, refuses any
pod in the namespace that does not turn it off or does not run in `isolated-sandbox`.

**Egress.** An `ApplicationNetworkPolicy` (`deploy/egress.yaml`) selects the agent pods,
which isolates them, and allows DNS, the Pod Identity agent at `169.254.170.23:80`, and
TCP 443 to three names only: `bedrock-runtime.<Region>.amazonaws.com`, the gateway's host,
and the run bucket's host. This is the EKS Best Practices Guide's default-deny start
(`latest/bpg/security/network.adoc:71-76`, same commit), with the allows layered on.

**The egress gate.** A new pod's network policy is not in force the moment the pod
starts. On this cluster the first request of a fresh agent pod reached `example.com` and
was answered `200`; the same request about 8 s later was refused (raw lines under
[Step 5](#step-5)). So `agent/run.sh` starts nothing until a host the rule does not name
(`example.com`, or `EGRESS_CANARY`) is refused three times in a row, and fails the run if
that has not happened after 90 s.

**State outside the pod.** The pod's filesystem is read-only apart from three `emptyDir`
volumes. The run's output goes to standard output, which `run.sh` streams as it happens
(EKS Auto Mode can remove the node as soon as a Job's pod finishes, and its logs with it),
and to `s3://<run bucket>/runs/<run id>/` before the pod exits.

**AWS resources it creates**, each tagged `ManagedBy=self-running-agents` and each named
from `NAME_PREFIX`: three IAM roles (`-agent`, `-gateway`, `-tool`), the Lambda function
`-clock` and its log group (one-day retention), the policy engine `<prefix>_policy` and its
one policy, the gateway `-gw` and its target `clock`, the run bucket, the ECR repository,
and one Pod Identity association. **In the cluster**: the namespace, a
`ValidatingAdmissionPolicy` and its binding (cluster-scoped, named for the namespace and
matching only it), the ServiceAccount, the egress rule and a ConfigMap with the bridge's
configuration and the prompt.

**Order.** `setup.sh` creates them in this order: namespace and admission, run bucket,
image, tool function, policy engine, gateway role and gateway, target and Cedar policy,
agent role and its association, then the ServiceAccount, egress rule and ConfigMap.
`cleanup.sh` removes them in reverse, reads each AWS delete back, and deletes the
namespace last, only when everything before it is gone.

### What this blueprint does not limit

**Name rules match addresses.** The egress rule's names are resolved to addresses and the
rule matches the addresses, not the name a client sends inside TLS. A host that shares an
address with an allowed name is reachable too. EKS Auto Mode also learns the addresses per
node, not per pod, so a pod can reach a name another pod on the same node is allowed.

**DNS is open.** Port 53 is allowed to any address, and the node answers every query, so
DNS can carry data out of the pod.

**The window before the policy.** The egress gate keeps the agent from starting during it,
but the window exists for every pod in the namespace. The cluster-wide way to close it is
the NodeClass's `networkPolicy: DefaultDeny` (the field the EKS Best Practices Guide shows
at `latest/bpg/security/automode.adoc:162-172`, same commit). That is a cluster-wide
setting, so this sample does not change it.

**The model call.** The agent reaches Bedrock directly with its own role. Nothing outside
the pod sees or meters those calls in this phase.

**Isolated sandboxes do not enforce Cedar or image signing.** The Cedar policy here is the
gateway's, in AWS. It says nothing about what runs inside the pod.

## Versions

| Component | Pin |
|---|---|
| Claude Code | `2.1.310` (Dockerfile) |
| `mcp-proxy-for-aws-cli` | `1.8.0` (Dockerfile; it pins its own dependency tree) |
| Base image | `public.ecr.aws/docker/library/node:22-bookworm-slim` |
| Lambda runtime | `python3.13` |
| EKS | 1.36, Auto Mode (this run: 1.36.5) |
| AWS CLI | 2.35.11 for this run |

## Files

| File | What it does |
|---|---|
| `.env.example` | The local values the scripts read; copy to `.env` |
| `Dockerfile`, `.dockerignore` | The agent image: Claude Code, the bridge, and `agent/` |
| `agent/run.sh` | Runs in the pod: egress gate, then the agent, a tool listing or an internet probe, then stores the output |
| `agent/settings.json` | Denies every built-in tool and allows only `mcp__gateway` |
| `agent/claude.json` | Marks `/work` trusted so a headless run does not stop at the trust prompt |
| `agent/prompt.txt` | The run's prompt |
| `agent/mcp_call.py` | Lists and calls the gateway's tools with no model in the loop |
| `tool/handler.py` | The Lambda function behind the gateway target |
| `policy/allow-get-time.cedar` | The one Cedar policy |
| `iam/*.json` | Trust and permission documents for the three roles |
| `deploy/admission.yaml` | The namespace's admission policy and binding |
| `deploy/serviceaccount.yaml` | The agent's ServiceAccount |
| `deploy/egress.yaml` | The agent pods' egress rule |
| `deploy/run-job.yaml` | One run's Job |
| `scripts/setup.sh`, `run.sh`, `test.sh`, `cleanup.sh` | Set up, run, check and remove; `common.sh` is shared |

## Run it

The output on this page comes from one fresh run on a cluster that had none of the
sample's resources. That run set `NAMESPACE=sra`, `NAME_PREFIX=sra` and
`ECR_REPOSITORY=sra-agent`, so those names appear below; the defaults are
`self-running-agents`. The account id is replaced with `<ACCOUNT_ID>`, the cluster name
with `<CLUSTER_NAME>`, and the generated ids of the gateway, the policy engine and the Pod
Identity association with `<id>`; long blocks are abridged where marked.

**Step 1: copy the settings and fill them in.**

```bash
cp .env.example .env
# set CLUSTER_NAME, and KUBE_CONTEXT to pin the cluster
```

**Step 2: set everything up.** `setup.sh` checks the runtime class and network policy
enforcement and changes neither.

```bash
./scripts/setup.sh
```

```text
== 0/9 checks ==
network policy enforcement is on, and ApplicationNetworkPolicy is available
account: <ACCOUNT_ID>   cluster: <CLUSTER_NAME>   run bucket: sra-runs-<ACCOUNT_ID>-us-west-2

== 1/9 namespace sra ==
namespace/sra created
namespace/sra labeled
validatingadmissionpolicy.admissionregistration.k8s.io/self-running-agents-sra created
validatingadmissionpolicybinding.admissionregistration.k8s.io/self-running-agents-sra created
...
== 5/9 policy engine sra_policy ==
  policy engine is ACTIVE

== 6/9 gateway sra-gw ==
arn:aws:iam::<ACCOUNT_ID>:role/sra-gateway
  gateway is READY
  gateway url: https://sra-gw-<id>.gateway.bedrock-agentcore.us-west-2.amazonaws.com/mcp

== 7/9 tool target clock and the Cedar policy ==
  target clock is READY
  policy allow_get_time is ACTIVE
...
== 9/9 the agent's ServiceAccount, egress rule and configuration ==
serviceaccount/agent created
applicationnetworkpolicy.networking.k8s.aws/agent-egress created
configmap/agent-config created
```

(Abridged: the image build and push and steps 2 to 4 and 8 are left out.)

**Step 3: start one agent run.** The agent reads the time through the gateway and reports
it. The pod has no service-account token, and waits for its egress rule before it starts.

```bash
./scripts/run.sh
```

```text
run 20261116t102831z-7dda73: mode agent, job agent-agent-20261116t102831z-7dda73
sra: run=20261116t102831z-7dda73 mode=agent start=2026-11-16T10:28:36Z
sra: kernel=6.18.62 uid=1000
sra: credential path absent: /var/run/secrets/kubernetes.io/serviceaccount
sra: credential path absent: /home/node/.aws
sra: egress gate: example.com:443 refused 3 times in a row after 15.1 s
sra: claude 2.1.310 (Claude Code)
...
sra: rc=0
sra: stored s3://sra-runs-<ACCOUNT_ID>-us-west-2/runs/20261116t102831z-7dda73/stream.jsonl
run 20261116t102831z-7dda73: job succeeded=1 failed=
```

(Abridged: the stream-json lines are left out.) The tool calls and the result, read from
that run's stream:

```text
tool_use: ToolSearch {"query": "select:mcp__gateway__clock___get_time", "max_results": 1}
tool_use: mcp__gateway__clock___get_time {"timezone": "UTC"}
result: time-in-utc: 2026-11-16T10:29:06+00:00 | turns 3 | is_error False
```

**Step 4: check it both ways.** `test.sh` runs the agent once more, then each refusal.

```bash
./scripts/test.sh
```

```text
T PASS: tool calls: ['ToolSearch', 'mcp__gateway__clock___get_time'] ... final: time-in-utc: 2026-11-16T10:29:06+00:00
T2 PASS: listed=['clock___get_time'] get_time={"timezone":"UTC","time":"2026-11-16T10:29:39+00:00"}
NC2 PASS: get_host_info isError=True text=Tool Execution Denied: Tool call not allowed due to policy enforcement [No policy applies to the request (denied by default).]
NC1 PASS: internet: https://example.com/ refused: URLError: <urlopen error [Errno 101] Network is unreachable>
NC4 PASS: sra: egress gate: bedrock-runtime.us-west-2.amazonaws.com:443 still reachable after 90 s sra: egress gate: the egress rule is not in force; stopping  run rc=1
NC3 PASS: token on: The pods "admission-check" is invalid: : ValidatingAdmissionPolicy 'self-running-agents-sra' with binding 'self-running-agents-sra' denied request: pods in this namespace must set ... | token off: pod/admission-check created (server dry run)

checks: 6 PASS, 0 FAIL
```

(Abridged: the T line's tool results and the NC3 message are cut where marked.)

- **T2 and NC2** call the gateway directly as the pod's role, with no model in the loop
  (`agent/mcp_call.py`), so the refusal is the gateway's, not the model's choice and not
  the bridge's. The gateway lists only `clock___get_time` and refuses `get_host_info` with
  a JSON-RPC error. The tool function's own log shows that only `get_time` reached it:

  ```text
        2 {"tool": "get_time"}
  ```

- **NC4** proves the egress gate fails closed: pointed at a host the rule does allow, it
  never sees a refusal, and the run stops before its tool call.

<a id="step-5"></a>
**Step 5: the window the egress gate is for.** This block is from a separate run of the
same Job with the gate replaced by a loop that requests `example.com` every few seconds
from the moment the pod starts:

```text
0.1 answered 200
8.1 refused URLError
16.1 refused URLError
...
120.5 refused URLError
```

## Good to know

- **A denied tool call is a JSON-RPC error.** The gateway answers a call the policy does not
  permit with an MCP error, `Tool Execution Denied: ... [No policy applies to the request
  (denied by default).]`, not with a tool result.
- **The bridge only offers listed tools.** `mcp-proxy-for-aws-cli` exposes the tools the
  gateway listed, so a call to an unlisted tool fails inside the pod. To see the gateway
  refuse it, call the gateway directly, as `agent/mcp_call.py` does.
- **A new role needs a few seconds.** Lambda and the gateway service both refuse a role
  created a moment before. `setup.sh` retries those two creates.
- **The run's logs.** Read a past run from the bucket:
  `aws s3 cp s3://<run bucket>/runs/<run id>/stream.jsonl -`.

## Clean up

```bash
./scripts/cleanup.sh
```

```text
== 1/8 the runs and the namespace's objects ==
No resources found
configmap "agent-config" deleted from sra namespace
applicationnetworkpolicy.networking.k8s.aws "agent-egress" deleted from sra namespace
serviceaccount "agent" deleted from sra namespace

== 2/8 Pod Identity association and agent role ==
  Pod Identity association a-<id> is gone
  role sra-agent is gone

== 3/8 gateway, its target and policy, and the policy engine ==
  gateway sra-gw-<id> is gone
  policy engine sra_policy-<id> is gone
  role sra-gateway is gone

== 4/8 tool function, its log group and role ==
  function sra-clock is gone
  log group /aws/lambda/sra-clock is gone
  role sra-tool is gone

== 5/8 image repository sra-agent ==
  repository sra-agent is gone

== 6/8 run bucket sra-runs-<ACCOUNT_ID>-us-west-2 ==
  bucket sra-runs-<ACCOUNT_ID>-us-west-2 is gone

== 7/8 admission policy ==
Warning: deleting cluster-scoped resources, not scoped to the provided namespace
validatingadmissionpolicybinding.admissionregistration.k8s.io "self-running-agents-sra" deleted
Warning: deleting cluster-scoped resources, not scoped to the provided namespace
validatingadmissionpolicy.admissionregistration.k8s.io "self-running-agents-sra" deleted

== 8/8 namespace sra ==
Warning: deleting cluster-scoped resources, not scoped to the provided namespace
namespace "sra" deleted
  namespace sra is gone

clean up complete
```

**What stays.** The runtime classes, the agent-sandbox install and network policy
enforcement, which this sample only reads.
