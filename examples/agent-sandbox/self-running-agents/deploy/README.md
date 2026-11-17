# deploy: one agent run

`run.yaml` is the template of one run: an `SraRun` instance of the graph in
[`kro/run-rgd.yaml`](../kro/README.md#what-srarun-makes). kro makes its one child, the run's
Job, and the Job's pod is the agent ([`agent/`](../agent/README.md)).

You do not apply it by hand. `scripts/run.sh` fills every placeholder for each run, creates it, follows the pod's logs, reads the Job's verdict, then deletes the
`SraRun` and the pod.

| Field | What it sets |
|---|---|
| `runID` | The run's id; the output goes to `runs/<run id>/` in the run bucket |
| `mode` | `agent` (Claude Code with the prompt) or `tools` (list and call tools, no model) |
| `probeCalls` | In `tools` mode, the tool names to call |
| `egressCanary` | The host the egress gate waits to fail to reach (`run.sh` sets `example.com` unless `EGRESS_CANARY` is set) |
| `image` | The agent image in the sample's ECR repository |
| `runBucket`, `region` | Where the output goes |
| `bifrostNamespace`, `modelID` | Where the model calls go, and which model |

**Deleting a run.** Delete its `SraRun`, then its pod
([why](../kro/README.md#what-srarun-makes)). A pod left behind keeps its own 15-minute
deadline ([limits](../agent/README.md#changing-it)), then stops and frees its node.

```bash
kubectl -n sra delete srarun <name>
kubectl -n sra delete pod -l self-running-agents/run=<its runID>
```

Every field is required except `probeCalls`; the graph sets no defaults.

An interrupted `run.sh`, a run with no verdict 60 s after its logs end, or one whose pod
does not start within 10 minutes leaves its `SraRun` in place for `cleanup.sh`.
