---
title: Aurora Engineering Handbook
tags: [aurora, cache, engineering, handbook]
date: 2026-08-28
authors:
  - platform-team
status: living-document
aliases: ["Aurora Handbook", "Cache Handbook"]
---

# Aurora Engineering Handbook

Aurora is our distributed, write-through cache layer sitting in front of the
primary datastore. This handbook is the ==single source of truth== for how it
is built, deployed, and operated. It is intentionally opinionated: where two
approaches are both reasonable we pick one and move on, rather then debating
it again every quarter.

%% Internal note: keep this doc under 45 pages when printed. Anything longer
belongs in the design-doc archive, not the handbook. %%

If you're new here, read [[#Architecture Overview]] first, then
[[#Getting Started|the getting-started guide]] below. Experianced operators
can skip straight to [[#Runbooks]].

## Table of Contents

1. [[#Architecture Overview]]
2. [[#Getting Started]]
3. [[#Consistency Model]]
4. [[#Configuration Reference]]
5. [[#Client Libraries]]
6. [[#Benchmarks]]
7. [[#Runbooks]]
8. [[#Team Notes]]
9. [[#Known Issues]]
10. [[#Appendix]]

---

## Architecture Overview

Aurora is composed of three tiers: the **edge routers**, the **cache rings**,
and the **backing store adapters**. Requests enter through an edge router,
which hashes the key and forwards it to the owning ring member. A ring member
either serves the value from memory or, on a miss, asks the backing store
adapter to fetch it and populate the cache before replying.

> [!note]
> Aurora is **not** a general-purpose cache. It assumes keys are short
> (< 256 bytes), values are small-to-medium (< 1 MiB), and reads vastly
> outnumber writes. If your workload doesn't look like that, talk to the
> platform team before adopting it — theres a good chance a different tool
> fits better.

The topology, from a single client's perspective, looks roughly like this
(depth intentionally exaggerated to excercise deeply nested lists):

- Edge tier
  - Router pool (stateless)
    - Consistent-hash ring lookup
      - Primary owner
        - Local shard
          - In-memory segment (LRU-ish, see below)
            - Hot key promotion path
      - Replica owner (for reads under load-shedding)
        - Local shard
          - In-memory segment
- Storage tier
  - Adapter pool
    - Postgres adapter
    - S3 cold-blob adapter (large values only)

And the equivalent view from the operator's side, numbered because runbooks
reference these steps by number:

1. Provision
   1. Reserve capacity in the fleet planner
      1. Confirm the AZ balance
         1. Two AZs minimum
            1. Three preferred for anything customer-facing
               1. Four is overkill — don't
2. Bootstrap
   1. Seed the ring from the last known-good snapshot
      1. Verify checksum
         1. Reject on mismatch
            1. Page the on-call
               1. Do not silently continue

Lazy continuation matters here, so a paragraph like this one:

> Requests that miss every tier fall through to the adapter pool, which is
allowed to be slow — adapters are rate-limited independently of the router
tier, so a slow adapter degrades hit latency for the affected keys only,
not the whole ring.
> A second quoted line follows immediately, still part of the same block.

is still one blockquote even though the middle line drops the `>` marker —
this is deliberate CommonMark behavior we rely on when writing these docs by
hand, and its worth testing that the editor doesn't accidently split it into
two blocks.

### A Note on Terminology

We consistently confuse "ring member" and "shard" in casual conversation.
For the purposes of this document:

- A **ring member** is a process (one per host, usually).
- A **shard** is a fixed slice of the hash space owned by exactly one ring
  member at a time (ownership moves during rebalancing).
- A **segment** is the in-memory data structure a shard uses to actually
  store key/value pairs.

#lexicon items like these get their own tag so the doc-search extension can
group them: #lexicon #glossary

---

## Getting Started

Clone the repo, install dependencies, and run the local ring:

```bash
git clone git@github.com:example-org/aurora.git
cd aurora
./scripts/bootstrap.sh --profile=local
aurora-ring start --members=3 --replicas=1
```

Once the ring reports healthy, point a client at it. Here's the same "hello
world" request in each of our supported languages.

```swift
import AuroraClient

let client = try AuroraClient(endpoints: ["localhost:9401"])
let value = try await client.get("greeting")
print(value ?? "no value cached yet")
try await client.set("greeting", value: "hello, aurora", ttl: .seconds(60))
```

```rust
use aurora_client::Client;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let client = Client::connect("localhost:9401").await?;
    let value: Option<String> = client.get("greeting").await?;
    println!("{:?}", value);
    client.set("greeting", "hello, aurora", Duration::from_secs(60)).await?;
    Ok(())
}
```

```python
from aurora_client import Client

client = Client(endpoints=["localhost:9401"])
value = client.get("greeting")
print(value or "no value cached yet")
client.set("greeting", "hello, aurora", ttl=60)
```

```typescript
import { AuroraClient } from "@example-org/aurora-client";

const client = new AuroraClient({ endpoints: ["localhost:9401"] });
const value = await client.get("greeting");
console.log(value ?? "no value cached yet");
await client.set("greeting", "hello, aurora", { ttlSeconds: 60 });
```

```go
package main

import (
	"context"
	"fmt"
	"time"

	aurora "example.org/aurora-client-go"
)

func main() {
	client, err := aurora.Connect(context.Background(), "localhost:9401")
	if err != nil {
		panic(err)
	}
	value, _ := client.Get(context.Background(), "greeting")
	fmt.Println(value)
	client.Set(context.Background(), "greeting", "hello, aurora", 60*time.Second)
}
```

The local ring's default config is checked into the repo as JSON:

```json
{
  "ringMembers": 3,
  "replicationFactor": 1,
  "shardCount": 256,
  "segment": {
    "kind": "lru",
    "maxEntries": 100000,
    "maxBytes": 268435456
  },
  "adapters": {
    "primary": "postgres",
    "cold": "s3"
  }
}
```

And the deployment manifest is YAML, generated from the same source of truth:

```yaml
apiVersion: aurora.example.org/v1
kind: RingDeployment
metadata:
  name: aurora-prod-us-east
  labels:
    team: platform
    tier: cache
spec:
  members: 12
  replicationFactor: 2
  resources:
    cpu: "4"
    memory: 8Gi
  adapters:
    - name: postgres-primary
      kind: postgres
      dsn: "postgres://aurora:${AURORA_DB_PASSWORD}@db.internal:5432/aurora"
    - name: s3-cold
      kind: s3
      bucket: aurora-cold-blobs
```

If your language isn't listed above, or you just want to see how the editor
handles a fence it doesn't recognize, here's one in a made-up language:

```zorbscript
fn hail(who) {
    print("hail, " ++ who ++ "!")
}
```

And a completely bare fence, no language tag at all — common enough in real
documents that its worth covering:

```
plain preformatted text
no highlighting applied here
```

---

## Consistency Model

Aurora offers **read-your-writes** consistency within a single client
connection, and **eventual consistency** across connections during a
rebalance. This is a deliberate trade-off: strict linearizability would
require a consensus round on every write, which we measured at roughly
40x the latency of the current fire-and-forget-to-replicas approach.

The replication lag bound is derived from the gossip fanout. With $n$ ring
members and a fanout of $f$, the expected number of gossip rounds to reach
full convergence is:

$$
R(n, f) = \left\lceil \frac{\ln n}{\ln f} \right\rceil
$$

For our production ring ($n = 96$, $f = 3$), that's $R(96, 3) = 5$ rounds,
and each round is bounded at $150\text{ms}$, giving a worst-case convergence
time of $750\text{ms}$. In practice we observe $p99$ convergence around
$210\text{ms}$ because gossip rarely needs the full fanout to reach every
member — most members hear the update from more than one neighbor.

The full derivation, including the tail bound we use for alerting
thresholds, is:

$$
\begin{aligned}
P[\text{not converged after } r \text{ rounds}]
  &\le n \cdot (1 - f/n)^{r} \\
  &\le n \cdot e^{-fr/n} \\
\implies r &\ge \frac{n}{f} \ln\!\left(\frac{n}{\delta}\right)
  \quad \text{for failure probability } \delta
\end{aligned}
$$

We alert if measured convergence exceeds the $\delta = 0.01$ bound for more
than three consecutive windows — a single blip is expected noise, a
sustained miss usually means a network partition or a mis-sized fanout.

Inline math is used constantly in code review comments too, e.g. "this loop
is $O(n \log n)$ not $O(n^2)$ like the PR description claims" — so the
editor needs to handle short inline math cleanly mixed into ordinary
sentances like this one, wich it does.

---

## Configuration Reference

The following table is intentionally wide — it's the kind of reference table
that shows up in real handbooks and is worth stress-testing against the
content column:

| Key | Type | Default | Environment Override | Description | Since | Restart Required | Notes |
|---|---|---|---|---|---|---|---|
| `ringMembers` | int | `3` | `AURORA_RING_MEMBERS` | Number of ring members in this deployment | v0.1 | yes | Must be odd for quorum reads |
| `replicationFactor` | int | `1` | `AURORA_REPLICATION_FACTOR` | How many replicas per shard | v0.1 | yes | 2 recommended for prod |
| `shardCount` | int | `256` | `AURORA_SHARD_COUNT` | Fixed hash-space slices | v0.1 | yes | Never change after first boot |
| `segment.kind` | enum | `lru` | `AURORA_SEGMENT_KIND` | `lru`, `lfu`, or `arc` eviction | v0.2 | yes | `arc` recommended for mixed workloads |
| `segment.maxEntries` | int | `100000` | `AURORA_SEGMENT_MAX_ENTRIES` | Per-shard entry cap | v0.1 | no | Soft cap, enforced async |
| `segment.maxBytes` | int | `268435456` | `AURORA_SEGMENT_MAX_BYTES` | Per-shard byte cap | v0.1 | no | Checked on every insert |
| `gossip.fanout` | int | `3` | `AURORA_GOSSIP_FANOUT` | Peers notified per gossip round | v0.3 | no | Higher = faster convergence, more chatter |
| `gossip.intervalMs` | int | `150` | `AURORA_GOSSIP_INTERVAL_MS` | Delay between gossip rounds | v0.3 | no | Don't go below `50` |
| `adapters.primary` | string | `postgres` | `AURORA_PRIMARY_ADAPTER` | Backing store for cache misses | v0.1 | yes | `postgres` or `mysql` |
| `adapters.cold` | string | `s3` | `AURORA_COLD_ADAPTER` | Backing store for large/cold values | v0.4 | yes | Optional, unset disables cold tier |

Rollout checklist for a config change (some done, some not — this is a
living checklist, not a finished one):

- [x] Change reviewed by platform team
- [x] Rolled out to staging ring
- [x] Soak for 24h minimum
- [ ] Canary 5% of prod ring
- [ ] Canary 25% of prod ring
- [ ] Full prod rollout
- [ ] Post-rollout dashboard review

---

## Client Libraries

We publish first-party clients and ~~an unofficial community one~~ (the
community one was archived in 2025 — use the official Rust client instead,
it has a thinner FFI layer now).

Autolinks are common in this section since we're mostly pointing at package
registries: <https://pkg.example.org/aurora-client-swift>,
<https://crates.io/crates/aurora-client>, and
<https://pypi.org/project/aurora-client/>.

See the [full API reference][api-ref] for method-level documentation, or the
[migration guide][migration-guide] if you're upgrading from the v0 client.

Every client exposes the same core surface:

```typescript
interface AuroraClient {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, opts?: { ttlSeconds?: number }): Promise<void>;
  delete(key: string): Promise<void>;
  getMulti(keys: string[]): Promise<Map<string, string>>;
}
```

Retries are handled inside the client, not by the caller — this was a
deliberate API choice after we noticed every team was re-implementing the
same exponential-backoff-plus-jitter loop, each with slightly different (and
occassionally wrong) jitter bounds.

<div class="callout-note">
  <strong>Raw HTML block:</strong> this handbook is exported to a static
  site as well as read inside Edmund, and a few pages embed hand-written
  HTML like this div for layout the Markdown renderer can't express.
</div>

---

## Benchmarks

Numbers below are from the October 2025 load test, three-node ring, `c6i.2xlarge`
instances, 10M keys, 90/10 read/write mix. Each row is the median of five
interleaved runs, never five runs of A then five of B — alternating avoids the
thermal-throttling bias that made an earlier version of this table wrong.

| Scenario | p50 (ms) | p95 (ms) | p99 (ms) | Throughput (req/s) |
|---|---|---|---|---|
| Warm read, local shard | 0.4 | 0.9 | 2.1 | 210,000 |
| Warm read, remote shard | 1.1 | 2.4 | 5.8 | 140,000 |
| Cold read (adapter fetch) | 8.2 | 22.0 | 61.0 | 12,000 |
| Write, no replication | 0.6 | 1.3 | 3.0 | 95,000 |
| Write, 2x replication | 1.8 | 4.1 | 9.6 | 61,000 |
| Rebalance in progress (read) | 2.3 | 6.7 | 15.2 | 88,000 |

> [!tip]
> If you're benchmarking a change, run it against this exact harness
> (`bench/ring_bench.rs`) so the numbers are comparable to this table. A
> harness written from scratch almost always measures something subtly
> different and the comparison is meaningless.

---

## Runbooks

### A ring member is unresponsive

1. Check `aurora-ctl status <member>` — if it reports `unreachable`, confirm
   the host is actually down (not just the Aurora process):
   ```bash
   aurora-ctl status ring-member-07
   ssh ring-member-07 uptime
   ```
2. If the host is up but the process is wedged, restart it:
   ```bash
   ssh ring-member-07 sudo systemctl restart aurora-ring
   ```
3. If the host is down, evict it from the ring so its shards rebalance onto
   healthy members:
   ```bash
   aurora-ctl evict ring-member-07 --reason="host down, restart pending"
   ```

> [!warning]
> Never `evict` a member that's merely slow-but-responding. Eviction
> triggers a full rebalance, which is expensive and will make things worse
> for a member that's just under temporary load. Use `aurora-ctl drain`
> instead — it moves shards gradually instead of all at once.

### A ring member is unresponsive- <!-- deliberately not a real heading, just prose that starts similarly -->

Not a real section — this line exists to make sure heading-adjacent prose
doesn't confuse the block parser.

### Split-brain during a network partition

> [!danger]
> This is the scenario that actually paged someone at 3am in March 2026.
> Read this whole section before touching anything.

When a network partition splits the ring into two groups that can each see
a majority... wait, they can't both see a majority, that's the point. If
gossip convergence alerts fire on **both** sides of what you believe is a
partition, do not restart anything until you've confirmed which side has
quorum:

```bash
aurora-ctl quorum-check --side=a
aurora-ctl quorum-check --side=b
```

The minority side must be fenced (stopped from accepting writes) before the
partition heals, or you'll get divergent writes that need manual
reconciliation — a process that has, historically, taken multiple days and
involved someone from data-eng reading raw WAL segments by hand. We would
very much like to never do that again.

---

## Team Notes

Not everything in this handbook is a runbook. The platform team also keeps
informal notes here — onboarding photos, offsite pictures, the occasional
diagram someone sketched on a whiteboard and photographed.

![Team offsite, north ridge trail|600](mountain-lake.jpg)

*Photo from the spring offsite — the "walk and design-review" session where
the current shard-rebalancing algorithm was actually sketched out, on the
trail pictured above.*

![alt|400x250](mountain-ridge.jpg)

The pipeline itself, roughly, looks like the diagram below (this is the
"parse -> style -> layout" pipeline from an unrelated internal tool, kept here
because its a good general shape reference and nobody's redrawn it for
Aurora specifically yet):

![Generic pipeline diagram](pipeline-diagram.svg)

And yes, most of us really do have three monitors of scrolling logs open at
all times:

![A ring member's dashboard during a bad night](code-screens.jpg)

![[forest-canopy.jpg]]

The embed above (double-bracket form) is the same mechanism Obsidian users
already know — Aurora's docs started life as an Obsidian vault before we
migrated most of it into Edmund, and some embeds never got converted to the
plain image syntax.

---

## Observability

Every ring member exports metrics in the usual format; the dashboards
worth knowing about are listed below rather then buried in a wiki page
nobody can find:

| Dashboard | Covers | Primary audience |
|---|---|---|
| Ring Overview | Per-member hit rate, latency percentiles, shard count | On-call, daily glance |
| Gossip Convergence | Convergence time per round, alert threshold overlay | On-call, during incidents |
| Adapter Health | Adapter latency, error rate, connection pool state | Platform team |
| Capacity Planning | Growth trend, projected exhaustion date per ring | Platform team, quarterly |

> [!info]
> The Capacity Planning dashboard's projection is a simple linear fit over
> the trailing 90 days. It is *not* a forecast in any statistically
> rigorous sense — it exists to flag "you have roughly N weeks before this
> becomes urgent," not to be precise to the day. Don't build automation
> that depends on its exact numbers.

Alerting thresholds live in the deployment manifest alongside everything
else, so they get reviewed the same way a config change does:

```yaml
alerts:
  - name: gossip-convergence-p99
    metric: aurora_gossip_convergence_ms
    threshold: 750
    window: 3
    severity: page
  - name: hit-rate-degraded
    metric: aurora_hit_rate
    comparison: below
    threshold: 0.85
    window: 5
    severity: ticket
  - name: adapter-connection-exhaustion
    metric: aurora_adapter_pool_available
    comparison: below
    threshold: 2
    window: 1
    severity: page
```

A common mistake when adding a new alert: setting `window: 1`, which means
a single bad sample pages someone. Almost every metric here is noisy enough
that a window of at least 3 is neccessary to avoid false pages — the
`adapter-connection-exhaustion` alert above is the one deliberate exception,
because by the time the pool is down to 2 connections a single bad sample
usually **is** real.

### On-call expectations, briefly

- Primary on-call acknowledges a page within 5 minutes.
- If the runbook in [[#Runbooks]] resolves it, close it out and write a
  one-line summary in the incident channel — don't skip this even for
  "boring" pages, the summaries are what make the quarterly incident
  review possible at all.
- If it's not in the runbook, or the runbook doesn't work, escalate to
  secondary immediately rather then spending twenty minutes trying things
  alone. Nobody's judged for escalating early; people are occassionally
  quietly judged for escalating too late.
- Anything that touched [[#Split-brain during a network partition]] always
  gets a full postmortem, no exceptions, regardless of how quickly it
  resolved.

---

## Known Issues

> [!bug]
> **Shard count changes are not yet online.** Changing `shardCount` still
> requires a full ring restart, which means a maintenance window. Fixing
> this properly requires virtual shards (many more logical shards than
> physical ones, remapped without moving data), which is scheduled but not
> started.[^virtual-shards]

> [!question]
> **Should cold-tier reads count against the hot-tier SLO?** Open question,
> genuinely unresolved. Argue about it in #aurora-design, not in this doc.

> [!failure]
> **The Postgres adapter leaks connections under sustained 5xx from the
> primary.** Known since v0.3, tracked as AUR-441. Workaround: set
> `adapters.postgres.maxConnections` conservatively and let the pool
> exhaust gracefully instead of the process OOMing.

> [!example]
> A minimal repro for AUR-441, if you want to see it yourself:
> ```bash
> aurora-local down-adapter postgres-primary
> aurora-local hammer --qps=500 --duration=60s
> watch -n1 'aurora-ctl adapter-stats postgres-primary'
> ```

> [!abstract]
> **Summary of open items**, for anyone skimming: virtual shards (design
> phase), cold-tier SLO policy (undecided), AUR-441 connection leak
> (workaround exists, real fix not started).

The collapsible callout below starts folded by default — expand it if you
need the detail, it's long and most readers don't:

> [!note]- Full incident timeline for the March 2026 split-brain
> - **02:14** — gossip convergence alert fires on `us-east-a`
> - **02:15** — gossip convergence alert fires on `us-east-b` (both sides!)
> - **02:19** — on-call confirms this is a real partition, not a flapping
>   alert, via `aurora-ctl quorum-check`
> - **02:31** — minority side (`us-east-b`, 4 of 12 members) fenced
> - **03:02** — partition heals at the network layer
> - **03:04** — majority side automatically re-absorbs the fenced members
> - **03:40** — reconciliation script finishes; 3 keys needed manual review
> - **09:00** — postmortem scheduled

And this one starts expanded, also fine to collapse:

> [!tip]+ Faster quorum-check
> `aurora-ctl quorum-check --all` runs the check against every ring member
> in parallel instead of one side at a time — usually faster during an
> actual incident when every second matters.

---

## Security

Aurora is deployed behind the internal service mesh and never accepts
connections directly from the public internet — this is enforced at the
network layer, not just by convention, so don't rely on application-level
checks alone.

> [!caution]
> The gossip protocol between ring members is **unauthenticated** by
> design (it was to expensive, latency-wise, to add per-message signing
> given the gossip fanout numbers in [[#Consistency Model]]). This is only
> safe because gossip traffic never leaves the mesh's private subnet. If
> you're ever tempted to expose a ring member's gossip port for debugging,
> don't — tunnel through `aurora-ctl` instead.

Access to the admin API (`aurora-ctl`, and the HTTP endpoints it wraps)
is gated by the standard internal auth proxy. A few things worth knowing:

- Read-only operations (`status`, `quorum-check`) require the `aurora:read`
  scope.
- Mutating operations (`evict`, `drain`, config pushes) require
  `aurora:admin`, which is **not** granted by default even to platform team
  members — request it per-incident through the access tool, it expires
  automatically after 8 hours.
- `aurora-local` (the local dev harness) has no auth at all. Never point it
  at a real ring's hostname, even by accident — theres no confirmation
  prompt before it starts hammering whatever endpoint you gave it.

Secrets (database passwords, TLS keys) are injected via the deployment
manifest's `${VAR}` interpolation, sourced from the secrets manager at
deploy time — never checked into the repo, and never logged, even at debug
verbosity. If you find a secret in a log line, thats a sev-1, not a
"file a ticket eventually" issue.

### Threat model, briefly

| Threat | Mitigation | Residual risk |
|---|---|---|
| Unauthenticated gossip traffic sniffed/spoofed | Mesh-private subnet, no public routes | Trusted-insider risk only |
| Admin API abuse | Scoped, time-limited grants | Grant issued to wrong person |
| Secret leakage via logs | Structured logging with a redaction filter | Redaction filter has a bug |
| Cold-tier (S3) bucket misconfigured public | Bucket policy + automated scanner | Scanner lag between scans |

We accept the residual risks above rather than engineering them away
entirely — the cost of e.g. per-message gossip signing was measured and
judged not worth it for an internal-only protocol. This could change if
Aurora's threat model changes (e.g. if we ever run a ring across untrusted
infrastructure), but thats not on the roadmap right now.

---

## Testing

Every client library ships with a conformance suite that runs against a
real local ring (not mocks — we got burned once by a mocked test suite that
passed while the real client had a serialization bug the mock didn't
reproduce). The suite lives in `conformance/` at the repo root and is
language-agnostic: it's a sequence of operations described in JSON, and each
client's test runner replays them against `aurora-local`.

```json
[
  { "op": "set", "key": "k1", "value": "v1", "ttlSeconds": 60 },
  { "op": "get", "key": "k1", "expect": "v1" },
  { "op": "delete", "key": "k1" },
  { "op": "get", "key": "k1", "expect": null },
  { "op": "getMulti", "keys": ["k2", "k3"], "expect": {} }
]
```

Adding a new client language means implementing a conformance runner, not
re-deriving the test cases — this keeps behavior consistent across every
language binding, which matters more than it might seem: we've had bugs in
the past where the Python client silently treated an empty string and
`null` as equivalent and nobody noticed for two release cycles because it
happend to match what most callers wanted anyway.

Load tests are a separate concern from conformance and live in `bench/`.
The benchmark harness referenced in [[#Benchmarks]] is `bench/ring_bench.rs`
— written in Rust regardless of which client you're testing, because the
harness itself needs to generate load fast enough to actually saturate a
production-sized ring, and only the Rust client's overhead is low enough
not to become the bottleneck.

---

## Deployment Topology

Production runs across two regions, each with its own independent ring —
Aurora rings do **not** replicate across regions. This was a deliberate
choice: cross-region replication would mean either accepting much higher
write latency (waiting for the far region to ack) or accepting weaker
consistency guarantees than we're comfortable with, and every team we
talked to preffered "two independent caches, keep them warm independently"
over either of those trade-offs.

- `us-east` ring
  - 12 members
    - 3 availability zones
      - 4 members per AZ
        - Each member: `c6i.2xlarge`
          - 8 vCPU, 16 GiB RAM
            - ~10 GiB usable for cache segments after overhead
- `eu-west` ring
  - 8 members
    - 2 availability zones
      - 4 members per AZ
        - Each member: `c6i.xlarge`
          - 4 vCPU, 8 GiB RAM
            - ~4.5 GiB usable for cache segments after overhead

A region's ring is sized independently based on that region's traffic —
`eu-west` is smaller because it serves roughly a third of `us-east`'s
request volume, not because it's less important.

---

## Glossary

**Ring** — the full set of members participating in a single Aurora
deployment; see [[#A Note on Terminology]] for how this differs from a
shard.

**Rebalance** — the process of moving shard ownership between members,
triggered by a member joining, leaving, or being evicted.

**Gossip round** — one cycle of every member notifying `fanout` randomly
chosen peers about state changes it knows about; see [[#Consistency Model]]
for the convergence math.

**Cold tier** — the S3-backed adapter used for values above a size
threshold, kept seperate from the primary Postgres adapter because large
blobs behave very differently under load (S3 handles them fine; Postgres
does not).

**Fencing** — forcibly preventing a ring member (or a whole side of a
partition) from accepting writes, used during split-brain recovery; see
[[#Split-brain during a network partition]].

---

## Appendix

### Migrating from the v0 client

The v0 client (retired, but you'll still find it in old code) used
callback-style APIs everywhere. The v1+ clients are all async/await (or the
closest equivalent per language). A side-by-side, since this is the most
common question in #aurora-support:

```java
// v0 (retired) — callback style
client.get("key", (value, error) -> {
    if (error != null) {
        handleError(error);
        return;
    }
    System.out.println(value);
});
```

```java
// v1 — CompletableFuture, still occasionally seen in older services
client.getAsync("key").thenAccept(value -> {
    System.out.println(value);
}).exceptionally(err -> {
    handleError(err);
    return null;
});
```

Most services have finished migrating; the exceptions are tracked in
AUR-390 and mostly blocked on those services' own unrelated modernization
work, not on anything Aurora-side.

For C/C++ callers (a small number of latency-sensitive services link the
client directly rather than going through the sidecar):

```c
aurora_client_t *client = aurora_connect("localhost:9401");
aurora_value_t value;
if (aurora_get(client, "greeting", &value) == AURORA_OK) {
    printf("%.*s\n", (int)value.len, value.data);
    aurora_value_free(&value);
}
aurora_disconnect(client);
```

```cpp
auto client = aurora::Client::Connect("localhost:9401");
if (auto value = client->Get("greeting")) {
    std::cout << *value << std::endl;
}
```

The sidecar itself (which most services use instead of linking a client
directly) is configured via a small CSS-adjacent-looking config format for
its embedded status dashboard — yes, really, someone thought a tiny
CSS-in-config format was a good idea for theming the sidecar's local debug
page, and it stuck:

```css
.aurora-sidecar-status {
  --accent: #086DDD;
  --warn: #EC7500;
  --error: #CF222E;
  font-family: -apple-system, sans-serif;
}
.aurora-sidecar-status .shard-count {
  color: var(--accent);
  font-weight: 600;
}
```

And the dashboard's HTML shell, for completeness:

```html
<!doctype html>
<html>
  <head>
    <title>Aurora Sidecar</title>
    <link rel="stylesheet" href="status.css" />
  </head>
  <body>
    <main class="aurora-sidecar-status">
      <span class="shard-count">0 shards owned</span>
    </main>
  </body>
</html>
```

---

## FAQ

**Q: Why not just use an off-the-shelf cache like the usual suspects?**

We evaluated several before building Aurora. The short version: our access
pattern (very high read fanout on a relatively small hot key set, with
strict tail-latency requirements) didn't map cleanly onto any of them
without either accepting a much higher operational burden or giving up the
consistency guarantees described in [[#Consistency Model]]. The full
evaluation writeup is linked from the design doc archive, not reproduced
here — it was long, and most of the reasoning is specific to our workload
rather then generally useful.

**Q: Can I run Aurora outside the two supported regions?**

Not today. The deployment tooling assumes `us-east` or `eu-west`; adding a
third region is possible but nobody's done the work to generalize the
tooling yet. If you have a real need, talk to the platform team — don't
just hand-roll a third ring, it wont get the same operational support.

**Q: What happens if I set a TTL of zero?**

It's treated as "no expiry" today, which suprises people (a lot of other
systems treat `0` as "expire immediately"). This is arguably a footgun and
theres an open proposal to make zero an error instead, but changing it now
would be a breaking change for a few services that rely on the current
behavior, intentionally or not.

**Q: My reads are slower then the benchmark table. Why?**

Almost always one of: you're hitting the cold tier more than expected
(check `adapter-stats`), you're on a ring that's mid-rebalance (check
`aurora-ctl status`), or you're comparing against the *local shard* numbers
while your actual traffic is mostly *remote shard* (routing depends on
where your service is deployed relative to the ring). See
[[#Benchmarks]] for the full breakdown by scenario.

**Q: Is there a way to see this whole handbook as one page, not split by section?**

Yes — this file *is* that one page. Everything under this heading and above
[[#Appendix]] is generated from the same source; there's no separate
"single-page" export, because keeping two versions in sync is exactly the
kind of thing that quietly goes stale.

---

### Reference-style links

We use reference-style links for anything cited more than once in this
document, so a single URL change doesn't require hunting through the whole
handbook:

[api-ref]: https://docs.example.org/aurora/api "Aurora API Reference"
[migration-guide]: https://docs.example.org/aurora/migrating-from-v0 "Migrating from v0"

### Footnotes

Footnotes are used sparingly, mostly for citations or asides that would
otherwise interupt a paragraph's flow.[^gossip-paper] The virtual-shards
idea referenced above isn't original to us either.[^virtual-shards]

[^gossip-paper]: The convergence-time derivation in
    [[#Consistency Model]] follows the standard epidemic-gossip analysis;
    see Demers et al., "Epidemic Algorithms for Replicated Database
    Maintenance" (1987) for the original treatment.

[^virtual-shards]: Sometimes called "vnodes" elsewhere in the industry —
    Dynamo and Cassandra both use a version of this idea, though our
    remapping scheme differs because we don't need Dynamo's ownership
    handoff protocol.

### A worked example, end to end

Putting several things together — a numbered procedure, inline code, and a
block reference we can link back to from elsewhere in the doc:

1. A client calls `set("user:4471:profile", ..., ttl: 3600)`.
2. The router hashes `"user:4471:profile"` and forwards to the owning shard.
3. The shard writes to its in-memory segment and asynchronously replicates
   to `replicationFactor` other members.
4. The client's `set()` call returns as soon as the local write lands —
   replication happens in the background. ^set-returns-early

That last step is the one people get surprised by most often — see the
callout in [[#Consistency Model]] for why we chose it.

### Contributing to this handbook

Small fixes (typos, stale values, broken links) can go straight to a PR
against `docs/handbook/`. Larger changes — a new section, restructuring an
existing one — should get a quick heads-up in #aurora-design first, mostly
so we don't end up with two people independently rewriting the same section
in parallel, which has happend more then once.

A short style guide, since we don't have a seperate one:

- Prefer `[!note]` / `[!tip]` / `[!warning]` over inventing new ad-hoc
  callout types. If you genuinely need a new one, check
  [[#Known Issues]] and the extended callout list — it's probably already
  supported by the renderer, just not used yet in this doc.
- Use `[[#Heading]]` links liberally rather then repeating an explanation.
  A reader following a link and finding "see above" is fine; a reader
  finding a third, slightly different explanation of gossip convergence is
  not.
- Keep code examples runnable, or at least internally consistent with the
  variable/function names used elsewhere in the same section. A snippet
  that doesn't quite match the surrounding prose is worse then no snippet.
- Footnotes for citations and asides, not for anything load-bearing to the
  main explanation — if a reader needs the footnote to understand the
  paragraph, it shouldn't be a footnote.

```bash
# The handbook's own lint check, run in CI on every PR:
./scripts/lint-handbook.sh docs/handbook/
```

The lint script checks for broken `[[wikilinks]]`, orphaned footnote
definitions, and reference-style links with no matching `[ref]:` line — all
three have happend enough times in the git history that it seemed worth
automating rather then relying on review catching it every time.

### Deliberately malformed table (parser stress)

The row below has more cells than the header — real documents occasionally
have this by accident, and the parser needs to not fall over:

| A | B | C |
|---|---|---|
| 1 | 2 | 3 | 4 | 5 |
| x | y |

### A long unbroken code identifier

Sometimes a single token is longer than the content column, which is a
different stress case than a long *word* in prose:

```rust
const SHARD_OWNERSHIP_TRANSFER_DEADLINE_MILLISECONDS_BEFORE_FORCED_EVICTION: u64 = 30_000;
```

### Closing notes

This handbook is maintained by the platform team. If you notice something
thats wrong, out of date, or just confusingly written, fix it directly —
we'd much rather recieve a small correcting PR then have someone silently
work around stale docs. Its suprisingly common for a doc to be wrong for
months because everyone assumed someone else would definately notice and
fix it eventually, and in the mean time new engineers keep independently
discovering the same descrepancy and just working around it instead of
updating the source. Please don't be that person — a two-line diff fixing
a typo or a stale default value is always welcome, no need to ask permision
first.

Thanks for reading all the way to the bottom. #handbook #aurora
