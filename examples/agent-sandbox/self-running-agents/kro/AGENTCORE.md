# The AgentCore Gateway: the agent's only door to tools

The agent holds no tools of its own. Every tool it can call comes through one Amazon Bedrock
AgentCore Gateway, and the gateway asks a Cedar policy about every call before it passes it
on. The decision is made in AWS, outside the sandbox, by a policy you can read.

The `SraGateway` graph (`gateway-rgd.yaml`) makes all of it through ACK.

```text
agent pod (role sra-agent)
  |  MCP over HTTPS, signed with SigV4 by mcp-proxy-for-aws-cli
  v
Gateway sra-gw  (protocol MCP, inbound auth AWS_IAM)
  |  asks: may this caller call this tool?
  |-----> Policy engine sra_policy (mode ENFORCE) with one Cedar permit
  |  if permitted, as role sra-gateway:
  v
Target clock --> Lambda function sra-clock (get_time, get_host_info)
```

## The pieces

| Resource (id in the graph) | Name | What it does |
|---|---|---|
| `engine`, a `PolicyEngine` | `sra_policy` | Holds the Cedar policies. Policy engine and policy names allow no dashes. |
| `gwRole`, an IAM `Role` | `sra-gateway` | The gateway's own role. It may invoke only the function `sra-clock`, and ask only policy engines and gateways named for the sample (`sra_policy-*`, `sra-gw-*`). |
| `gateway`, a `Gateway` | `sra-gw` | Protocol `MCP`, inbound authorizer `AWS_IAM`, the policy engine attached in `ENFORCE` mode. |
| `target`, a `GatewayTarget` | `clock` | Points at the Lambda function and lists its two tools, `get_time` and `get_host_info`. The gateway calls the function with its own role (`GATEWAY_IAM_ROLE`). |
| `policy`, a `Policy` | `sra_allow_get_time` | The one Cedar `permit`, checked strictly (`FAIL_ON_ANY_FINDINGS`). |

The gateway names a tool `<target>___<tool>`, so the agent sees `clock___get_time`.

## How a call is decided

The gateway knows the caller by its SigV4 signature, so the Cedar principal is the pod's
role:

```text
permit (
  principal == AgentCore::IamEntity::"arn:aws:sts::<ACCOUNT_ID>:assumed-role/sra-agent",
  action == AgentCore::Action::"clock___get_time",
  resource == AgentCore::Gateway::"<the gateway's ARN>"
);
```

Cedar denies by default, so `get_host_info` is refused for the agent, and every tool is
refused for any other caller. The gateway also lists only the tools the policy permits, so
the agent's tool list holds `clock___get_time` alone.

A denied call is a JSON-RPC error, not a tool result:
`Tool Execution Denied: ... [No policy applies to the request (denied by default).]`. The
bridge offers only the tools the gateway listed, so to see the gateway refuse a tool, call
it directly, as `agent/mcp_call.py` does (`test.sh` checks T2 and NC2).

## The agent's side

- The agent's role `sra-agent` may call `bedrock-agentcore:InvokeGateway` on this gateway
  only. It has no `bedrock-agentcore:UpdateGateway` permission.
- The bridge, `mcp-proxy-for-aws-cli`, runs inside the pod as a stdio MCP server and signs
  each request. The ConfigMap `agent-config`, which `SraGateway` makes and every run mounts,
  carries its `mcp.json`, with the gateway's URL from the gateway's status.
- The egress rule lets the pod reach the gateway's host on 443.

## Things to know

- **The mode is the real control.** The policy engine's mode (`ENFORCE`) is a field on the
  gateway. Whoever holds `bedrock-agentcore:UpdateGateway` can set it to `LOG_ONLY` or remove
  the engine, so that permission is what to guard.
- **The gateway role is scoped by name, not exact ARN.** The role is made before the
  gateway, and kro cannot make the role and the gateway depend on each other. Making it
  first also avoids an IAM propagation failure that ACK would not retry. Its trust lets any
  AgentCore gateway in this account and Region assume it (`gateway/*`).
- **Where a refusal is recorded.** The gateway's own logs do not carry policy decisions. The
  `DenyDecisions` metric in `AWS/Bedrock-AgentCore` does, by default:
  `aws cloudwatch get-metric-statistics --namespace AWS/Bedrock-AgentCore --metric-name DenyDecisions ...`.
  Per-call decisions need traces on the gateway, which this sample does not turn on.
- **More tools.** Add a `GatewayTarget` to the graph for each, with its own Cedar `Policy`
  for the agent's role.
- **Quotas.** AgentCore Gateway and Policy have their own:
  [Quotas for Amazon Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/bedrock-agentcore-limits.html).
- **Private endpoints.** The gateway has an interface VPC endpoint,
  `com.amazonaws.<Region>.bedrock-agentcore.gateway`; this sample uses the public one.
