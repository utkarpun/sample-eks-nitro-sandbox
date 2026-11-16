# Bifrost: a model gateway for the agent

[Bifrost](https://github.com/maximhq/bifrost) is an open-source model gateway. Here it
calls Amazon Bedrock with a role of its own, for callers that send it Anthropic Messages
requests with a key that is not an AWS credential. **The agent in this sample still calls
Bedrock directly**: until four of the sample's files change, Bifrost runs beside it and
nothing routes the agent through it. Those files are `deploy/run-job.yaml` (the agent's
`CLAUDE_CODE_USE_BEDROCK` and model settings), `agent/settings.json` (an `apiKeyHelper`
that reads the key), `kro/gateway-rgd.yaml` (the agent role's two Bedrock statements and
the `bedrock-runtime` name in its egress rule) and `scripts/test.sh` (the egress canary).

What is code and what is not:

- **The Bifrost Deployment** comes from the official Helm chart, with `values.yaml`.
- **Everything around it** is one kro ResourceGraphDefinition, `rgd.yaml`, over AWS
  Controllers for Kubernetes (ACK), and its one instance, `instance.yaml`: the Postgres
  database on Amazon RDS with its security group and subnet group, Bifrost's IAM role and
  its EKS Pod Identity association, the ServiceAccount, a fixed name for the database
  (`Service bifrost-db`) and Bifrost's network policy. The namespace is `namespace.yaml`.
- **The four Secrets** (the database password, the encryption key, the admin login and the
  agent's key) are made by `apply.sh` from random bytes, because a manifest would have to
  hold their values.
- kro and ACK are the sample's own EKS managed capabilities, from `bootstrap/`.
- `apply.sh`, `test.sh` and `destroy.sh` wrap them: check the prerequisites, read the
  cluster's VPC, make the Secrets, apply, wait and read back.

```
caller pod (namespace sra, label app.kubernetes.io/name: agent)
   |  HTTP 8080, x-api-key: the agent's key
   v
Service bifrost (namespace bfx, normal runtime, 1 replica)
   |-- HTTPS 443  --> bedrock-runtime.<Region>.amazonaws.com   (role bfx-bifrost, Pod Identity)
   '-- TLS 5432   --> Postgres on RDS (Service bifrost-db)     (config, keys, counters)
```

## Why the state is in Postgres

A Bifrost pod may be replaced on any node: each replacement leaves a few seconds with no
answer, and EKS Auto Mode consolidation could do it at any time, so the pod carries
`karpenter.sh/do-not-disrupt` (BPG `latest/bpg/autoscaling/karpenter.adoc:544-552`
@edc514fac). Its configuration, the agent's key, the admin login and the usage counters
are in Postgres, and a new pod picks them up at start. Postgres runs on RDS, not in the
cluster, so a node change never moves the database.

- **One replica.** Bifrost OSS does not support several processes on one Postgres database
  (Bifrost docs, *runtime contract*: "Run one replica because live in-memory changes are
  not synchronized between OSS processes"). The EKS Best Practices Guide advises against
  singleton pods (`latest/bpg/reliability/application.adoc:38` @edc514fac); here it cannot
  be avoided.
- **No requests or answers are kept.** The chart cannot turn Bifrost's logs store off, so
  Bifrost makes an SQLite one in `/app/data` (an `emptyDir`). `enableLogging: false` keeps
  the logging plugin, which is what writes requests and answers there, from loading;
  `test.sh` checks that nothing under `/app/data` holds its prompt.
- **`config.json` wins on every start** (`sourceOfTruth: config.json`): what `values.yaml`
  names is put back as written, and anything made only through Bifrost's admin API for
  those sections is removed. Change the setup in `values.yaml`, never in the dashboard.
- **The database is single-AZ by default** (`dbMultiAZ: false` in `rgd.yaml`). Set it to
  true for a standby in a second AZ, which bills both the instance and its storage twice
  (Amazon RDS User Guide, *On-Demand DB instances for Amazon RDS*: "Multi-AZ deployments are
  priced higher than Single-AZ deployments, and can cost approximately twice as much").
- **Backups**: automated backups are kept 1 day (`dbBackupRetentionDays`). The clean up
  takes no final snapshot (ACK's default), so the data is gone with the instance.
- **TLS**: Bifrost connects with `sslMode: require`, and the default `postgres17` parameter
  group forces TLS (`rds.force_ssl` is `1`). The connection is encrypted but the server's
  certificate is not verified; `verify-full` would also need the RDS host name, where
  Bifrost is given the in-cluster alias `bifrost-db`.
- **Secrets as environment variables.** The chart gives the pod its Secrets as environment
  variables, where the EKS Best Practices Guide advises volume mounts
  (`latest/bpg/security/data.adoc:194-196` @edc514fac); the chart has no file form for them.

## What it costs

The RDS instance bills from `apply.sh` until `destroy.sh` ends with `clean up complete`:
`db.t4g.micro` Single-AZ PostgreSQL in `us-west-2` is $0.016 an instance hour, and its
20 GB of gp3 storage $0.115 per GB-month (AWS Price List, prices effective 2026-11-01, read
2026-11-16). Bedrock calls are billed as usual.

## Before you start

1. The sample's own prerequisites and its **Step 0, `bootstrap/`**, which turns on kro and
   ACK as EKS managed capabilities with one capability role (see
   [Self-running agents](../README.md)). `apply.sh` checks for their CRDs and stops with
   the `terraform` command if one is missing.
2. The sample's `./scripts/setup.sh`, which makes the namespace `sra` the callers run in.
   `apply.sh` copies the agent's key there.
3. `aws`, `kubectl`, `helm` 3, `python3` and `openssl` on your machine.

The names are fixed to fit `bootstrap/`'s scope (`bootstrap/variables.tf`): the namespace
`bfx` is in its `secret_namespaces` (ACK reads the database password there), and the AWS
names `bfx-bifrost` and `bfx-bifrost-db` and the tag `ManagedBy=bfx` match its
`rds_prefix`. To change them, change `rds_prefix` and `secret_namespaces`, `lib.sh`,
`namespace.yaml` and `instance.yaml` together.

The cluster, Region, kube context and model come from the sample's `.env`, as for the agent
(`CLUSTER_NAME`, `AWS_REGION`, `KUBE_CONTEXT`, `BEDROCK_MODEL_ID`). `apply.sh` writes the
Region and model into the instance (the role's policy and egress rule) and into
`values.yaml` (Bifrost's provider key and the key's allowed model). A different model also
needs its entries in `pricing/`.

**Pricing.** `pricing/pricing.json` and `pricing/model-parameters.json` hold the one entry
each that Bifrost reads for this model (`bedrock/us.anthropic.claude-sonnet-5-5` and
`us.anthropic.claude-sonnet-5-5`), copied on 2026-11-16 from the chart's default sources,
`https://getbifrost.ai/datasheet` and `https://getbifrost.ai/datasheet/model-parameters`, so
Bifrost needs no egress for them. To refresh, download both and copy the same two entries.

## Bring it up

```bash
./bifrost/apply.sh
```

The output blocks on this page are from one fresh run of `apply.sh`, `test.sh` and
`destroy.sh` on the sample's bootstrap.

```text
TODO: output from the fresh run
```

`apply.sh` makes the four Secrets once and never prints them; a re-run keeps them.

## Prove it

```bash
./bifrost/test.sh
```

```text
TODO: output from the fresh run
```

| Check | Accepts | Refuses |
|---|---|---|
| BQ-3 | Bifrost becomes Ready with its ApplicationNetworkPolicy present | |
| CALLER | a pod with Bifrost's ServiceAccount is `bfx-bifrost` | a pod with another ServiceAccount gets no role |
| IAM | the profile, and a model called through it | the model called directly |
| NC-B2 | the agent's key gets past auth | no key, a wrong key (401); the agent's key on a model outside its list (403) |
| T-B0 | one model call with the agent's key | |
| COST | Bifrost priced that call (`bifrost_cost_total`) | |
| LOGS | | the prompt kept anywhere under `/app/data` |
| NC-B7 | | an admin write with no login or a wrong one (401), nothing changed |
| NC-B5 | an agent-labelled pod in `sra` | a pod in `sra` without the label; an agent-labelled pod in `bfx` |
| T-B2 | a new pod with the key's token count kept, 1 replica answering | a key made only in the database (gone), 0 replicas (no answer) |

`test.sh` makes one model call in total. NC-B5's first leg needs the agent's egress rule to
allow Bifrost, which comes with the agent's switch above.

## How a caller uses it

A caller sets `ANTHROPIC_BASE_URL=http://bifrost.bfx.svc.cluster.local:8080/anthropic`,
names the model `bedrock/<model id>`, and reads its key from the Secret `bifrost-agent-key`.
Once the agent does, its own role needs no Bedrock permission and its egress rule no
Bedrock host.

**Network policy.** This fork ships Bifrost's network policy (and the agent's), though the
upstream repository's rules say a new sample ships none: it is what keeps Bifrost reachable
from agent pods only, with default deny and named allows (BPG
`latest/bpg/security/network.adoc:71-76` @edc514fac). Drop it if the sample is proposed
upstream.

## Stop it

- `kubectl -n bfx scale deploy/bifrost --replicas=0` stops every call through Bifrost.
- The agent's key is limited to 120 requests a minute and 40,000,000 tokens a day
  (`rl-agent` in `values.yaml`), shared by every run that uses it, and to the one model.
  There is no spend budget.

## Clean up

```bash
./bifrost/destroy.sh
```

```text
TODO: output from the fresh run
```

**If clean up is incomplete**, the lines above it say what is left. A graph that did not
delete in time leaves the namespace, its Secrets and possibly the RDS instance, which keeps
billing: check it with `kubectl -n bfx get bifrostbackend bifrost -o yaml` and
`aws rds describe-db-instances --db-instance-identifier bfx-bifrost`, then run
`./bifrost/destroy.sh` again.

It leaves kro and ACK, which come from `bootstrap/`.
