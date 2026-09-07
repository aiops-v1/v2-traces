# Metrics, Alerting & Traces (adds an OTel Collector + Tempo to v1-metrics)

Everything from `v1-metrics` still runs here — same Prometheus, same
Alertmanager, same two Grafana dashboards, same alert rules. This stage
doesn't replace that layer, it sits a third signal (**traces**) next to it,
because the interesting part of tracing isn't the trace store on its own,
it's the two places metrics and traces now touch: an exemplar dot on a
latency panel that jumps straight into the exact request that caused it,
and a trace whose own timeline shows you, span by span, where that
request's time actually went.

## What's running

The app repos are now `../expense-backend-v1.2` and `../expense-frontend-v1.2`
(siblings of this folder, alongside `../expense-mysql-v1`) — a fork of
`v1.1`, not a shared copy, made **specifically so `v1-metrics` keeps
teaching cleanly on its own**: a v1 student poking at `expense-backend-v1.1`
never has to see `tracing.js`, exemplar labels, or an nginx OTel module and
wonder what they are or why they're dormant. Everything that changed between
the two:

- **`expense-backend-v1.2`** — no code changes at all. `src/tracing.js` and
  the exemplar wiring in `src/metrics.js` (`enableExemplars: true`, a real
  `trace_id` attached to every `http_request_duration_seconds` observation)
  were already fully built and dormant in `v1.1` — `ENABLE_TRACING` defaults
  to on (`src/server.js`), and `v1-metrics` was the one place turning it
  back off because it had no collector to export to. This stage just doesn't
  set that override.
- **`expense-frontend-v1.2`** — the one real code change. `nginx.conf` now
  loads `ngx_otel_module.so` (already bundled in the `nginx:stable-alpine-otel`
  base image `v1.1` was already built on — nothing new to compile, unlike
  the from-source `nginx-module-vts` build) and turns tracing on only for
  `location /api/` — the one place nginx actually calls the backend, so the
  one place a span tells you anything. `location /` (serving the SPA's
  static files) stays untraced on purpose, to keep every trace in this stack
  about an actual API call, not favicon/JS/CSS noise.

New services, both introduced by this stage:
- **`otel-collector`** — the single place every span in this stack gets sent
  (nginx via OTLP/gRPC on `:4317`, the backend via OTLP/HTTP on `:4318` —
  two protocols on one receiver because that's genuinely what each side
  speaks, not redundancy), which forwards them on to Tempo. See
  `otel-collector/otel-collector-config.yaml`.
- **`tempo`** — where spans actually live. Deliberately configured *without*
  Tempo's own metrics-generator (the `span-metrics`/`service-graphs` setup
  Tempo's own docs demo) — see `tempo/tempo.yaml`'s own comment on why that
  would be a second, redundant bridge next to the one this app already
  built itself.

Everything else — Alertmanager, the exporters, cadvisor, `node-exporter`,
the alert rules, the SLO recording rules — is identical to `v1-metrics`,
with three additions: Prometheus now runs with
`--enable-feature=exemplar-storage` (see `docker-compose.yml`'s `prometheus`
service); the Prometheus/Grafana datasource wiring now points a `trace_id`
exemplar at the new Tempo datasource (see
`grafana/provisioning/datasources/datasource.yml`); and Prometheus now
scrapes `otel-collector` and `tempo` themselves (`prometheus/prometheus.yml`)
— neither exposes its own metrics reachably by default (the Collector's
default bind is loopback-only; see `otel-collector-config.yaml`'s
`telemetry` block), so without this addition, either one dying would've
been invisible to the stack. No new alert rule was needed for that:
`InstanceDown` (`alert-rules.yml`) is already `up == 0` across every job, so
the two new scrape targets are covered the moment they exist. Everything in
`v1-metrics`'s own README about the RED/business/MySQL/nginx/host&container
rows, `up`, `ALERTS`, and the whole SLO burn-rate section below still
applies unchanged — this README only adds what's actually new.

## Quick start

```bash
cd expense-app-stages/v2-traces
docker compose up -d --build
```

- App: `http://<host>/` (port 80, via nginx)
- Prometheus: `http://<host>:9090`
- Alertmanager: `http://<host>:9093`
- Grafana: `http://<host>:3000` (`admin` / `admin`)

Same alerting credential setup as `v1-metrics` (`alertmanager/secrets/README.md`),
same two load generators (`scripts/healthy-load.sh`, `scripts/fault-load.sh`),
same cold-start-is-empty caveat. otel-collector and Tempo have no host ports
published — nothing outside this Docker network needs to reach them
directly, only Grafana does, and Grafana already is.

---

## Distributed tracing — the third signal

### What's actually in a trace
A **trace** is one request's whole story, end to end, as a tree of
**spans** — one span per unit of work, each with a start time, a duration,
and a parent (except the root). For a `POST /api/expenses` call in this
stack, that tree looks roughly like:

```
nginx: /api/  (root span — created because location /api/ has otel_trace on)
  └─ backend: POST /expenses  (auto-instrumented by @opentelemetry/instrumentation-express)
       └─ mysql: INSERT INTO expenses ...  (auto-instrumented by @opentelemetry/instrumentation-mysql2)
```

Every span in that tree shares one `trace_id` — that's the thread Grafana
pulls on when you click an exemplar. **`getNodeAutoInstrumentations()`**
(`expense-backend-v1.2/src/tracing.js`) is what creates the backend/mysql
spans without a single line of manual instrumentation anywhere in
`routes/`— it patches `express` and `mysql2` at import time, which is also
exactly why `tracing.js` has to be `require()`'d before anything else in
`src/server.js`: patch too late, and the already-`require()`'d copies of
those libraries are the un-patched originals.

### How context gets from nginx to the backend
A browser doesn't send trace-context headers on its own — `nginx.conf`'s
`otel_trace_context propagate;` is what makes the root span exist at all: no
incoming context to extract, so nginx starts a brand-new trace, then
**injects** that trace's `traceparent` header into the proxied request
before it ever reaches `proxy_pass http://backend:4000/;`. The backend's own
auto-instrumentation then extracts that same header and continues the trace
as a child span, rather than starting a second, disconnected one. Turn
`otel_trace_context` to `ignore` (the module's own default) as a live demo
of what breaks: the backend's spans still get created and still reach
Tempo, but as their own standalone traces with no nginx span above them —
worth doing once, deliberately, to show *why* propagation is the piece that
actually stitches a multi-service trace together, not merely "having
tracing on everywhere."

### The exemplar bridge (Bridge #2)
This is the part that was already fully built before this stage existed —
`expense-backend-v1.2/src/metrics.js` reads
`trace.getActiveSpan().spanContext().traceId` inside the exact same
`res.on('finish')` handler that records every request's duration, and
attaches it as an exemplar on that one observation. Two settings, both new
in this stage, are what make that exemplar actually visible instead of
silently discarded:
- **`--enable-feature=exemplar-storage`** on Prometheus (`docker-compose.yml`)
  — without it, Prometheus accepts the OpenMetrics exposition format's
  exemplars during a scrape and throws them away anyway.
- **`exemplarTraceIdDestinations`** on the Prometheus datasource
  (`grafana/provisioning/datasources/datasource.yml`) — without it, Grafana
  still draws the little diamond marks on the p50/p95/p99 panels, but
  clicking one does nothing; this is the line that tells Grafana *which*
  datasource (`tempo`) a `trace_id` label actually points into.

To see it work: run `healthy-load.sh` for a bit, open the
`p99 request duration by method & route` panel (metrics dashboard), find a
diamond mark on the `POST /auth/signup` or `POST /auth/signin` line (the
two slowest routes in this app — see `v1-metrics`'s README section on the
SLO latency alert for why: `BCRYPT_ROUNDS = 12` in
`expense-backend-v1.2/src/routes/auth.js`), and click it. That jumps
straight into the one real trace behind that one data point.

### What that trace actually shows — and doesn't
Opening the signup trace, the backend span for `POST /auth/signup` is
long, but its *own* child spans (the mysql `INSERT`) are short — most of
the span's duration is unaccounted for by any child span at all. That gap
is `bcrypt.hash()` running: CPU-bound, synchronous, and not a library
`getNodeAutoInstrumentations()` knows how to instrument, so it never gets a
span of its own. This is worth naming as a real, general limitation, not a
gap in this particular setup: a trace only shows you time spent *inside
instrumented libraries* (HTTP calls, DB queries, and similar). Time spent
in your own application code — a slow loop, a heavy computation, bcrypt —
shows up only as silence between spans. Reading that silence correctly
("something happened here, in code the tracer doesn't see automatically")
is as much a skill as reading the spans themselves.

### A preview of the logs stage, already running
`expense-backend-v1.2`'s log lines already carry `trace_id`/`span_id` on
every entry — `@opentelemetry/instrumentation-pino` (bundled into
`getNodeAutoInstrumentations()`) injects both automatically the moment
tracing is on, independent of whether anything is querying by them yet
(`src/middleware/requestLogger.js` has the full story on why they're
*not* bound manually in this codebase). `docker compose logs backend` will
already show them on every JSON line in this stage — there's no Loki here
yet to search "all logs for this trace_id", but the correlation key itself
already exists, which is exactly what the logs stage picks up.

### What's still deliberately missing
No Tempo `search` by attribute other than `trace_id` beyond what Grafana's
Explore already gives you for free, no span metrics/service graph (see
`tempo/tempo.yaml`'s note on why), and no log store to actually pivot from a
trace into its matching log lines yet — that pivot is real, working
groundwork (`trace_id`/`span_id` already on every log line), just not
wired to anything queryable until the logs stage adds Loki.


