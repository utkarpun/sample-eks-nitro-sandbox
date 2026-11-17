# Bifrost: the agent's model gateway

[Bifrost](https://github.com/maximhq/bifrost) is an open-source model gateway. Here it
calls Amazon Bedrock with a role of its own, for callers that send it Anthropic Messages
requests with a key that is not an AWS credential. The agent is such a caller: its role has
no Bedrock statement and its egress rule no `bedrock-runtime` name (`kro/gateway-rgd.yaml`),
so its model calls reach Bedrock only through Bifrost.

```
caller pod (namespace sra, label app.kubernetes.io/name: agent)
   |  HTTP 8080, x-api-key: the agent's key
   v
Service bifrost (namespace bfx, normal runtime, 1 replica)
   |-- HTTPS 443  --> bedrock-runtime.<Region>.amazonaws.com   (role bfx-bifrost, Pod Identity)
   '-- TLS 5432   --> Postgres on RDS (Service bifrost-db)     (config, keys, counters)
```

## What is in this folder

| File | What it is |
|---|---|
| `rgd.yaml`, `instance.yaml` | The `BifrostBackend` kro graph and its one instance: everything around Bifrost |
| `values.yaml` | The values for Bifrost's official Helm chart |
| `pricing/` | The model's price and parameters, which Bifrost reads locally |
| `apply.sh`, `test.sh`, `destroy.sh` | Bring it up, prove it, take it down; `lib.sh` is shared |

**The graph makes:** Bifrost's namespace `bfx`, the PostgreSQL database on Amazon RDS with its
security group and subnet group, Bifrost's IAM role and its EKS Pod Identity association,
the ServiceAccount, a fixed in-namespace name for the database (`Service bifrost-db`), the
pricing ConfigMap, Bifrost's network policy, and the agent's copy of its key in `sra`. The
instance is cluster scoped, because it makes the namespace, and deleting it deletes the
namespace last. The key copy is written with `base64.encode`, because kro puts no bytes in a
template and its error says to encode them
([conversions.go](https://github.com/kubernetes-sigs/kro/blob/v0.10.0/pkg/cel/conversion/conversions.go#L105):
"encode it explicitly, e.g. base64.encode(...)"). The EKS kro capability's version is not in
AWS's docs (read it with `aws eks describe-capability`), so whether the capability accepts
that form is first shown when the graph goes ACTIVE in the sample's first fresh run.

**The Helm chart makes** the Bifrost Deployment.

**`apply.sh` makes** the four Secrets (the database password, the encryption key, the admin
login and the agent's key) from random bytes, once the graph has made the namespace: their
values must be secret, and kro's generators (`random.seededString`, `random.seededInt`) are
deterministic from their seed, so a graph cannot make fresh random bytes; a secret value has
to be made outside it ([kro CEL libraries](https://github.com/kubernetes-sigs/kro/blob/main/website/docs/docs/concepts/expressions/02-cel-libraries.md)). It makes them once and
never prints them; a re-run keeps them.

## Why the state is in Postgres

A Bifrost pod may be replaced on any node, and each replacement leaves a few seconds with no
answer. EKS Auto Mode consolidation could do it at any time, so the pod carries
`karpenter.sh/do-not-disrupt` (EKS Best Practices Guide,
[*Karpenter*](https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html)). Its
configuration, the agent's key, the admin login and the usage counters are in Postgres, and
a new pod picks them up at start. Postgres runs on RDS, not in the cluster, so a node change
never moves the database.

- **One replica.** Bifrost OSS does not support several processes on one database (Bifrost
  docs, *runtime contract*: "Run one replica because live in-memory changes are not
  synchronized between OSS processes"). The EKS Best Practices Guide advises against
  singleton pods ([*Running highly-available
  applications*](https://docs.aws.amazon.com/eks/latest/best-practices/application.html));
  here it cannot be avoided.
- **No requests or answers are kept.** The chart cannot turn Bifrost's logs store off, so
  Bifrost makes an SQLite one in `/app/data` (an `emptyDir`). `enableLogging: false` keeps the
  logging plugin, which writes requests and answers there, from loading; `test.sh` checks
  that nothing under `/app/data` holds its prompt.
- **`config.json` wins on every start** (`sourceOfTruth: config.json`): what `values.yaml`
  names is put back as written, and anything made only through the admin API for those
  sections is removed. Change the setup in `values.yaml`, never in the dashboard.
- **Single-AZ by default** (`dbMultiAZ: false` in `rgd.yaml`). True gives a standby in a second
  AZ, which bills the instance and its storage twice (Amazon RDS User Guide, *On-Demand DB
  instances for Amazon RDS*: "Multi-AZ deployments are priced higher than Single-AZ
  deployments, and can cost approximately twice as much").
- **Backups** are kept 1 day (`dbBackupRetentionDays`). The clean up takes no final snapshot
  (ACK's default), so the data goes with the instance.
- **TLS.** Bifrost connects with `sslMode: require`, and the default `postgres17` parameter
  group forces TLS (`rds.force_ssl` is `1`). The connection is encrypted, but the server's
  certificate is not verified; `verify-full` would also need the RDS host name, where Bifrost
  is given the alias `bifrost-db`.
- **Secrets as environment variables.** The chart gives the pod its Secrets as environment
  variables, where the EKS Best Practices Guide advises volume mounts ([*Data encryption and
  secrets
  management*](https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html));
  the chart has no file form for them.

## What it costs

The RDS instance bills from `apply.sh` until `destroy.sh` ends with `clean up complete`:
`db.t4g.micro` Single-AZ PostgreSQL in `us-west-2` is $0.016 an instance hour, and its 20 GB
of gp3 storage $0.115 per GB-month (AWS Price List, prices effective 2026-11-01, read
2026-11-16). Bedrock calls are billed as usual.

## Before you start

1. The sample's prerequisites and its Step 0, [`bootstrap/`](../bootstrap/README.md).
   `apply.sh` checks for the kro and ACK CRDs and stops with the `terraform` command if one is
   missing.
2. The sample's `./scripts/setup.sh`, which makes the namespace `sra` the callers run in.
   The graph makes the agent's copy of the key there.

The names are fixed to fit `bootstrap/`'s scope: the namespace `bfx` is in its
`secret_namespaces` (ACK reads the database password there), and the AWS names
`bfx-bifrost` and `bfx-bifrost-db` and the tag `ManagedBy=bfx` match its `rds_prefix`. To
change them, change every `bfx` together (`git grep -n bfx` in this sample's folder).

The cluster, Region, kube context and model come from the sample's `.env` (`CLUSTER_NAME`,
`AWS_REGION`, `KUBE_CONTEXT`, `BEDROCK_MODEL_ID`, and `AWS_PROFILE`); leave out `--context`
in the commands below when `KUBE_CONTEXT` is empty. `apply.sh` writes the Region and model
into the instance (the role's policy and the egress rule) and into a rendered copy of
`values.yaml` (Bifrost's provider key and the key's allowed model). A different model also
needs its entries in `pricing/`.

**Pricing files.** `pricing/pricing.json` and `pricing/model-parameters.json` hold the one
entry each that Bifrost reads for this model (`bedrock/us.anthropic.claude-sonnet-5-5` and
`us.anthropic.claude-sonnet-5-5`), copied on 2026-11-16 from the chart's default sources,
`https://getbifrost.ai/datasheet` and `https://getbifrost.ai/datasheet/model-parameters`, so
Bifrost needs no egress for them. `apply.sh` puts both into the instance as strings, and the
graph makes the ConfigMap `bifrost-pricing` from them. To refresh, download both, copy the
same two entries, and run `apply.sh` again.

## Bring it up

```bash
./bifrost/apply.sh
```

The output blocks on this page will come from one fresh run of `apply.sh`, `test.sh` and
`destroy.sh`; Bifrost's graph has not yet run on a cluster.

```text
TODO: output from the fresh run
```

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
| IAM (simulated) | the profile, and a model called through it | the model called directly |
| NC-B2 | the agent's key gets past auth | no key, a wrong key (401); the agent's key on a model outside its list (403) |
| T-B0 | one model call with the agent's key | |
| COST | Bifrost priced that call (`bifrost_cost_total`) | |
| LOGS | | the prompt kept anywhere under `/app/data` |
| NC-B7 | | an admin write with no login or a wrong one (401), nothing changed |
| NC-B5 | an agent-labelled pod in `sra` | a pod in `sra` without the label; an agent-labelled pod in `bfx` |
| T-B2 | a new pod with the key's token count kept, 1 replica answering | a key made only in the database (gone), 0 replicas (no answer) |

`test.sh` makes one model call in total.

## How a caller uses it

A caller sets `ANTHROPIC_BASE_URL=http://bifrost.bfx.svc.cluster.local:8080/anthropic`,
names the model `bedrock/<model id>`, and reads its key from the Secret `bifrost-agent-key`.
The agent does this in `kro/run-rgd.yaml` and `agent/settings.json`.

**Network policy.** Bifrost's network policy lets only agent pods reach it, with default
deny and named allows (EKS Best Practices Guide, [*Network
security*](https://docs.aws.amazon.com/eks/latest/best-practices/network-security.html)).

## Stop it

- `kubectl --context <KUBE_CONTEXT> -n bfx scale deploy/bifrost --replicas=0` stops every
  call through Bifrost.
- The agent's key is limited to 120 requests a minute and 40,000,000 tokens a day (`rl-agent`
  in `values.yaml`), shared by every run that uses it, and to the one model. There is no
  spend budget.

## Clean up

```bash
./bifrost/destroy.sh
```

```text
TODO: output from the fresh run
```

`destroy.sh` uninstalls the Helm release and deletes the graph instance, which has ACK delete
the RDS database (no final snapshot), its subnet group and security group, Bifrost's role and
its Pod Identity association; it waits up to 25 minutes. kro deletes the agent's copy of the
key in `sra`, and the namespace `bfx` last, with the Secrets in it. Then `destroy.sh`
deletes the graph `bifrost-backend` and its kind `bifrostbackends.kro.run`, and reads each
back.

**If clean up is incomplete**, the lines above it say what is left. A graph that did not
delete in time leaves the namespace, its Secrets and possibly the RDS instance, which keeps
billing: check it with `kubectl --context <KUBE_CONTEXT> get bifrostbackend bifrost -o yaml`
and `aws rds describe-db-instances --region <AWS_REGION> --db-instance-identifier bfx-bifrost`,
then run `./bifrost/destroy.sh` again.

It leaves kro and ACK, which come from `bootstrap/`, so run it before you remove them; if
one is already gone, see
[*If kro or ACK is already gone*](../scripts/README.md#if-kro-or-ack-is-already-gone).
