# agent: what runs inside the sandbox pod

These files, except `prompt.txt`, go into the agent image (the sample's `Dockerfile`), which
`setup.sh` builds and pushes to the ECR repository `sra`. One image runs every mode. The pod
is the run's Job from the `SraRun` graph ([`kro/`](../kro/README.md)).

| File | What it does |
|---|---|
| `run.sh` | The pod's entry point: the egress gate, then the agent or a tool listing, then stores the output |
| `settings.json` | Claude Code's settings: allows only `mcp__gateway`, and its `apiKeyHelper` reads the Bifrost key from `/vk/key` |
| `claude.json` | Marks `/work` trusted, so a headless run does not stop at the trust prompt |
| `prompt.txt` | A reference copy of the prompt ([`kro/`](../kro/README.md#good-to-know)) |
| `mcp_call.py` | Lists and calls the gateway's tools with no model in the loop |

The image is Node with Claude Code and the bridge `mcp-proxy-for-aws-cli`, which signs
each MCP request to the gateway with SigV4 (versions: [Versions](../README.md#versions)). The
gateway's address is not baked in: it comes from the ConfigMap `agent-config`, which
`SraGateway` makes and every run mounts, because it is known only after setup.

## What a run does

`run.sh` reads `RUN_MODE`:

- **`agent`**: headless Claude Code (`claude -p`) with the prompt from `/cfg/prompt.txt`.
  Its built-in tools are off (`--tools ""`), so its only tools are the gateway's.
- **`tools`**: list the gateway's tools and call each name in `PROBE_CALLS`, with no model,
  so a refusal is the gateway's and not the model's choice. `test.sh` uses this.

The output goes to standard output, which `scripts/run.sh` streams as it happens, and, on a
normal exit, to `s3://<run bucket>/runs/<run id>/`. A run stopped at its 15-minute deadline
stores nothing; the streamed log is its only record. Nothing is kept in the pod. The
root filesystem is read-only, so the home directory is an `emptyDir`.

## The egress gate

A new pod's network policy is not in force the moment the pod starts. On this cluster the
first request of a fresh agent pod reached `example.com` and was answered `200`; the same
request about 8 s later was refused. This block is from a separate, earlier run, made before
the `SraRun` graph, of the same pod spec (then a bare Job), with the gate replaced by a loop
that requests `example.com` every few seconds from the moment the pod starts:

```text
0.1 answered 200
8.1 refused URLError
16.1 refused URLError
...
120.5 refused URLError
```

So `run.sh` starts nothing until a connection to a host the egress rule does not name
(`example.com`, or `EGRESS_CANARY`) fails three times in a row, and fails the run if that has
not happened after 90 s. A pod exit of 3 means the gate failed, and nothing was stored.

Any failure to connect counts (refused, unreachable, timed out or not resolvable), so the
gate only means something when the canary is reachable before the rule applies. On a cluster
with no internet path, set `EGRESS_CANARY` to a host the pod can otherwise reach, with
`export EGRESS_CANARY=<host>` in your shell before you run `run.sh` or `test.sh` (it is not
read from `.env`).

## Changing it

- **The prompt**: see [`kro/`](../kro/README.md#good-to-know).
- **A repository to work in**: a step in `run.sh` before Claude Code starts, with the
  repository's host added to the egress rule in `kro/gateway-rgd.yaml`.
- **Limits**: a run stops 15 minutes after its Job starts, pod scheduling and the image pull
  included (`activeDeadlineSeconds: 900` on the Job and on its
  pod, in `kro/run-rgd.yaml`), is not retried (`backoffLimit: 0`), and the model gets at most
  8 turns (`--max-turns 8` in `run.sh`).
