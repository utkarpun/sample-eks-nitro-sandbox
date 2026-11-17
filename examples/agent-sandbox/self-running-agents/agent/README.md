# agent: what runs inside the sandbox pod

These files go into the agent image (the sample's `Dockerfile`), which `setup.sh` builds
and pushes to the ECR repository `sra`. One image runs every mode. The pod is the run's Job
from the `SraRun` graph ([`kro/`](../kro/README.md)).

| File | What it does |
|---|---|
| `run.sh` | The pod's entry point: the egress gate, then the agent or a tool listing, then stores the output |
| `settings.json` | Claude Code's settings: allows only `mcp__gateway`, and its `apiKeyHelper` reads the Bifrost key from `/vk/key` |
| `claude.json` | Marks `/work` trusted, so a headless run does not stop at the trust prompt |
| `prompt.txt` | The prompt's text; `kro/gateway.yaml` carries the copy a run uses |
| `mcp_call.py` | Lists and calls the gateway's tools with no model in the loop |

The image is `public.ecr.aws/docker/library/node:22-bookworm-slim` with Claude Code
`2.1.310` and the bridge `mcp-proxy-for-aws-cli` `1.8.0`, which signs each MCP request to
the gateway with SigV4. The gateway's address is not baked in: it comes from the run's
ConfigMap, because it is known only after setup.

## What a run does

`run.sh` reads `RUN_MODE`:

- **`agent`**: headless Claude Code (`claude -p`) with the prompt from `/cfg/prompt.txt`.
  Its built-in tools are off (`--tools ""`), so its only tools are the gateway's. It gets at
  most 8 turns (`--max-turns 8`).
- **`tools`**: list the gateway's tools and call each name in `PROBE_CALLS`, with no model,
  so a refusal is the gateway's and not the model's choice. `test.sh` uses this.

The output goes to standard output, which `scripts/run.sh` streams as it happens, and to
`s3://<run bucket>/runs/<run id>/` before the pod exits. The pod's role may only put objects
under `runs/`. Nothing is kept in the pod. The root filesystem is read-only, so the home
directory is an `emptyDir`.

## The egress gate

A new pod's network policy is not in force the moment the pod starts. On this cluster the
first request of a fresh agent pod reached `example.com` and was answered `200`; the same
request about 8 s later was refused (the README's Step 5).

So `run.sh` starts nothing until a connection to a host the egress rule does not name
(`example.com`, or `EGRESS_CANARY`) fails three times in a row, and fails the run if that has
not happened after 90 s. A pod exit of 3 means the gate failed, and nothing was stored.

Any failure to connect counts (refused, unreachable, timed out or not resolvable), so the
gate only means something when the canary is reachable before the rule applies. On a cluster
with no internet path, set `EGRESS_CANARY` to a host the pod can otherwise reach, with
`export EGRESS_CANARY=<host>` in your shell before you run `run.sh` or `test.sh` (it is not
read from `.env`).

## Changing it

- **The prompt**: the `prompt` field in `kro/gateway.yaml`, which the graph puts in the run's
  ConfigMap.
- **A repository to work in**: a step in `run.sh` before Claude Code starts, with the
  repository's host added to the egress rule in `kro/gateway-rgd.yaml`.
- **Limits**: the 15-minute limit (while the run's Job exists) is in `kro/run-rgd.yaml`, the 8 turns here in `run.sh`.
