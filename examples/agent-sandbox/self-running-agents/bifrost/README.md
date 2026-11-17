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

**The graph makes** the namespace `bfx`, the PostgreSQL database on Amazon RDS with its
security group and subnet group, Bifrost's IAM role and Pod Identity association, the
ServiceAccount, the Service `bifrost-db` (a fixed name for the database), the pricing
ConfigMap, Bifrost's network policy, and the agent's copy of its key in `sra`. The instance
is cluster scoped, because it makes the namespace; deleting it deletes the namespace last.

**The Helm chart makes** the Bifrost Deployment.

**`apply.sh` makes** the four Secrets (the database password, the encryption key, the admin
login and the agent's key) from random bytes, once, and never prints them. A graph cannot
make them, because kro's generators are deterministic from their seed
([kro CEL libraries](https://github.com/kubernetes-sigs/kro/blob/main/website/docs/docs/concepts/expressions/02-cel-libraries.md)).

## Why the state is in Postgres

A Bifrost pod may be replaced on any node, so it carries `karpenter.sh/do-not-disrupt` (EKS
Best Practices Guide, [*Karpenter*](https://docs.aws.amazon.com/eks/latest/best-practices/karpenter.html)),
and its configuration, keys, admin login and usage counters live in Postgres on RDS, which a
new pod reads at start.

- **One replica.** Bifrost OSS cannot share one database between processes (Bifrost docs,
  *runtime contract*), so the singleton the EKS Best Practices Guide advises against
  ([*Running highly-available applications*](https://docs.aws.amazon.com/eks/latest/best-practices/application.html))
  cannot be avoided here.
- **No requests or answers are kept.** `enableLogging: false` keeps the logging plugin off;
  `test.sh` checks that nothing under `/app/data` holds its prompt.
- **`config.json` wins on every start.** Change the setup in `values.yaml`, never in the
  dashboard: anything made only through the admin API is removed.
- **Single-AZ by default** (`dbMultiAZ: false` in `rgd.yaml`). Multi-AZ can cost about twice
  as much (Amazon RDS User Guide, *On-Demand DB instances for Amazon RDS*).
- **Backups** are kept 1 day. The clean up takes no final snapshot, so the data goes with the
  instance.
- **TLS** is required (`sslMode: require`, and the default `postgres17` parameter group forces
  it), but the server's certificate is not verified: `verify-full` would need the RDS host
  name, where Bifrost is given the alias `bifrost-db`.
- **Secrets as environment variables**, where the EKS Best Practices Guide advises volume
  mounts ([*Data encryption and secrets management*](https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html));
  the chart has no file form for them.

## What it costs

The RDS instance bills from `apply.sh` until `destroy.sh` ends with `clean up complete`:
`db.t4g.micro` Single-AZ PostgreSQL in `us-west-2` is $0.016 an instance hour, and its 20 GB
of gp3 storage $0.115 per GB-month (AWS Price List, prices effective 2026-11-01, read
2026-11-16). Bedrock calls are billed as usual.

## Before you start

1. The sample's prerequisites and its Step 0, [`bootstrap/`](../bootstrap/README.md).
   `apply.sh` stops with the `terraform` command if a kro or ACK CRD is missing.
2. The sample's `./scripts/setup.sh`, which makes the namespace `sra`.

The cluster, Region, kube context and model come from the sample's `.env`. The names `bfx`
are fixed to fit `bootstrap/`'s `rds_prefix` and `secret_namespaces`; to change them, change
every `bfx` together (`git grep -n bfx` in this sample's folder). A different model also
needs its entries in `pricing/`, which hold the one entry Bifrost reads for this model,
copied on 2026-11-16 from `https://getbifrost.ai/datasheet` and
`https://getbifrost.ai/datasheet/model-parameters`, so Bifrost needs no egress for them. To
refresh, copy the same entries again and run `apply.sh`.

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
names the model `bedrock/<model id>`, and reads its key from the Secret `bifrost-agent-key`,
as the agent does in `kro/run-rgd.yaml`. Bifrost's network policy lets only agent pods reach
it.

## Stop it

- `kubectl --context <KUBE_CONTEXT> -n bfx scale deploy/bifrost --replicas=0` stops every
  call through Bifrost.
- The agent's key is limited to 120 requests a minute and 40,000,000 tokens a day (`rl-agent`
  in `values.yaml`), shared by every run, and to the one model. There is no spend budget.

## Clean up

```bash
./bifrost/destroy.sh
```

```text
TODO: output from the fresh run
```

`destroy.sh` uninstalls the Helm release and deletes the graph instance, so ACK deletes the
database (no final snapshot) and the rest, and kro deletes the namespace `bfx` last. Then it
deletes the graph and reads each piece back; it waits up to 25 minutes.

**If clean up is incomplete**, the lines above it say what is left, and the RDS instance may
still bill: check `aws rds describe-db-instances --region <AWS_REGION> --db-instance-identifier bfx-bifrost`,
then run `./bifrost/destroy.sh` again. Run it before you remove kro and ACK; if one is
already gone, see
[*If kro or ACK is already gone*](../scripts/README.md#if-kro-or-ack-is-already-gone).
