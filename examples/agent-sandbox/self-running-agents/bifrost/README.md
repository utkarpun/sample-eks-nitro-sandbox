# Bifrost: the agent's only way to a model

[Bifrost](https://github.com/maximhq/bifrost) is an open-source model gateway. Here it is the
one place that may call Amazon Bedrock: the agent sends Anthropic Messages requests to
Bifrost with a key that is not an AWS credential, and Bifrost calls the one inference
profile with a role of its own. Everything is infrastructure as code:

- **The Bifrost Deployment** comes from the official Helm chart, with `values.yaml`.
- **Everything around it** is one kro ResourceGraphDefinition, `rgd.yaml`, over AWS
  Controllers for Kubernetes (ACK): the Postgres database on Amazon RDS with its security
  group and subnet group, Bifrost's IAM role and its EKS Pod Identity association, the
  ServiceAccount, a fixed name for the database (`Service bifrost-db`) and Bifrost's
  network policy.
- `apply.sh`, `test.sh` and `destroy.sh` only wrap them: check the prerequisites, read the
  cluster's VPC, make the Secrets, apply, wait and read back.

```
agent pod (namespace AGENT_NAMESPACE, isolated-sandbox, no Bedrock permission)
   |  HTTP 8080, x-api-key: the agent's key
   v
Service bifrost (namespace BIFROST_NAMESPACE, normal runtime, 1 replica)
   |-- HTTPS 443  --> bedrock-runtime.<Region>.amazonaws.com   (role <NAME_PREFIX>-bifrost, Pod Identity)
   '-- TLS 5432   --> Postgres on RDS (Service bifrost-db)     (config, keys, counters)
```

## Why the state is in Postgres

The Bifrost pod is meant to come and go, on any node, without anyone noticing. So it keeps
nothing itself: its configuration, the agent's key, the admin login and the request
counters are in Postgres, and a new pod picks them up at start. Postgres runs on RDS, not
in the cluster, so EKS Auto Mode consolidating a node never moves the database.

- **One replica.** Bifrost OSS does not support several processes on one Postgres database
  (Bifrost docs, *runtime contract*: "Run one replica because live in-memory changes are
  not synchronized between OSS processes"). While the one pod is being replaced, a call
  gets no answer for the seconds it takes the new pod to start.
- **`config.json` wins on every start** (`sourceOfTruth: config.json`): what `values.yaml`
  names is put back as written, and anything made only through Bifrost's admin API for
  those sections is removed. Change the setup in `values.yaml`, never in the dashboard.
- **The database is single-AZ by default** (`dbMultiAZ: false` in the instance). Set it to
  true for a standby in a second AZ, at twice the instance price.
- **Backups**: automated backups are kept 1 day (`dbBackupRetentionDays`). The clean up
  takes no final snapshot (ACK's default), so the data is gone with the instance.
- **TLS**: Bifrost connects with `sslMode: require`, and the default `postgres17` parameter
  group forces TLS (`rds.force_ssl` is `1`).

## Before you start

1. The sample's own prerequisites (cluster, network policy enforcement): see the sample's
   page.
2. **kro and the ACK `ec2`, `rds`, `iam` and `eks` controllers** on the cluster. They are a
   shared install: `apply.sh` checks for their CRDs and stops if one is missing. Each ACK
   controller needs its own role through Pod Identity, allowed to manage only this
   sample's resources (the `ManagedBy` tag and the `<NAME_PREFIX>-` names). If kro runs
   with `rbac.mode: aggregation`, `kro-rbac.yaml` (applied by `apply.sh`) grants it the
   kinds this graph uses.
3. `aws`, `kubectl`, `helm` 3, `python3` and `openssl` on your machine.

Set, in your shell:

| Variable | What it is | Default |
|---|---|---|
| `CLUSTER_NAME` | your EKS Auto Mode cluster | none |
| `AWS_REGION` | its Region | `us-west-2` |
| `KUBE_CONTEXT` | its kube context | the current one |
| `BIFROST_NAMESPACE` | Bifrost's namespace; `apply.sh` makes and labels it | `self-running-agents-bifrost` |
| `AGENT_NAMESPACE` | the agent's namespace, whose agent pods may call Bifrost | `self-running-agents` |
| `NAME_PREFIX` | the prefix of every AWS name | `self-running-agents` |
| `MANAGED_BY` | the `ManagedBy` tag and namespace label | `self-running-agents` |

The model and Region are in two places, kept equal by hand: `providers` and
`governance` in `values.yaml`, and `modelID` and `region` in the instance (`apply.sh`).

## Bring it up

```bash
./bifrost/apply.sh
```

From a fresh run with `BIFROST_NAMESPACE=bfx`, `AGENT_NAMESPACE=bfx-agent`,
`NAME_PREFIX=bfx-w` and `MANAGED_BY=bfx`, so the names differ from the defaults. The
cluster name, account, VPC and subnet IDs and the database host are replaced with
placeholders, and two Helm warnings about another chart in the local repository cache are
left out.

```text
cluster <CLUSTER_NAME>: account <ACCOUNT_ID>, VPC <VPC_ID> (192.168.0.0/16), subnets <SUBNET_ID_1>,<SUBNET_ID_2>,<SUBNET_ID_3>
namespace/bfx created
namespace/bfx labeled
secret bfx/bifrost-db made
secret bfx/bifrost-encryption made
secret bfx/bifrost-admin made
secret bfx/bifrost-agent-key made
secret bfx-agent/bifrost-agent-key made
waiting for the graph (RDS takes about 5 to 10 minutes)
database bfx-w-bifrost.<DB_HOST_ID>.us-west-2.rds.amazonaws.com
bifrost is up: http://bifrost.bfx.svc.cluster.local:8080
```

`apply.sh` makes four Secrets once, from random bytes, and never prints them: the database
password, the encryption key, the admin login and the agent's key (`bifrost-agent-key`,
also copied into `AGENT_NAMESPACE` when that namespace exists). A re-run keeps them.

## Prove it

```bash
./bifrost/test.sh
```

From the same deployment, with the same names. The role session name is replaced with a
placeholder.

```text
BQ-3 PASS: ready replicas 1 with ApplicationNetworkPolicy bifrost in force
CALLER PASS: caller is arn:aws:sts::<ACCOUNT_ID>:assumed-role/bfx-w-bifrost/<SESSION_NAME>
IAM PASS: profile allowed; model alone implicitDeny; model through the profile allowed
NC-B2 PASS: no key 401, wrong key 401; the agent's key on a model outside its list 403
T-B0 PASS: HTTP 200, answer 'ok'
NC-B7 PASS: write without login 401; keys before 'agent', after 'agent'
NC-B5 PASS: agent-labelled pod REACHED, other pod REFUSED
T-B2 PASS: db-only create 200; count 66 -> 66; keys 'agent db-only' -> 'agent'; pod bifrost-76f75c8fff-lrz4c -> bifrost-76f75c8fff-qcst6; key check 403 replicas 0: REFUSED; replicas 1: REACHED 
8 passed, 0 failed
```

| Check | Accepts | Refuses |
|---|---|---|
| BQ-3 | Bifrost becomes Ready with its ingress rule in force | |
| CALLER | a pod with Bifrost's ServiceAccount is `<NAME_PREFIX>-bifrost` | the node's role (instance metadata is off) |
| IAM | the profile, and a model called through it | the model called directly |
| NC-B2 | the agent's key gets past auth | no key, a wrong key (401) |
| T-B0 | one model call with the agent's key | |
| NC-B7 | | an admin write without the login (401), nothing changed |
| NC-B5 | an agent-labelled pod in `AGENT_NAMESPACE` | any other pod |
| T-B2 | a new pod with the key's token count kept, 1 replica answering | a key made only in the database (gone), 0 replicas (no answer) |

`test.sh` makes one model call in total.

## How the agent uses it

The agent sets `ANTHROPIC_BASE_URL=http://bifrost.<BIFROST_NAMESPACE>.svc.cluster.local:8080/anthropic`,
names the model `bedrock/<model id>`, and reads its key from the Secret `bifrost-agent-key`
with `apiKeyHelper`. Its own role then needs no Bedrock permission, and its egress rule no
Bedrock host.

## Stop it

- `kubectl -n <BIFROST_NAMESPACE> scale deploy/bifrost --replicas=0` stops every model call.
- There are no budgets in this setup: the rate limit (`rl-agent`, requests per minute), the
  role's one profile and each run's deadline are the limits.

## Clean up

```bash
./bifrost/destroy.sh
```

From the same names. The first four lines are from the fresh run's clean up; the
read-back lines are from running `destroy.sh` again straight after, with the IAM role
lookup this page ships (the fresh run's version read a paged list and could not tell).

```text
release bifrost removed
deleting the graph (RDS takes about 5 to 10 minutes)
bifrostbackend.kro.run "bifrost" deleted
namespace bfx removed
RDS instance bfx-w-bifrost: gone
DB subnet group bfx-w-bifrost: gone
security group bfx-w-bifrost-db: gone
IAM role bfx-w-bifrost: gone
Pod Identity association bfx/bifrost: gone
clean up complete
```

It leaves kro and the ACK controllers, which are a shared install.
