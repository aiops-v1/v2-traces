# Load scripts

Both scripts are plain bash + curl (no k6, no jq) and talk to the app only
through nginx on port 80 (`$BASE_URL/api/...`), the same path a real
browser uses — never the backend's `:4000` directly.

## `healthy-load.sh`
Signs up a new random user, then creates a few expenses against one of the
app's default categories (read via `GET /categories`, not created). This is
what "normal traffic" looks like on the RED-metrics and business-metrics
panels — request rate ticking up, `users_registered_total` and
`expenses_created_total` climbing, error rate flat at zero.

```bash
BASE_URL=http://localhost USERS=20 EXPENSES_PER_USER=5 ./healthy-load.sh

# or leave it running continuously while you look at the dashboard:
DURATION_SECONDS=300 ./healthy-load.sh
```

## `fault-load.sh`
Sends genuinely invalid requests — wrong password, duplicate signup, weak
password, no auth cookie, unknown route, malformed JSON — to put real 4xx
and 5xx traffic on the error-rate panel. This stage doesn't set
`ENABLE_DEBUG_ROUTES` (a backend flag that would otherwise expose a
`/debug` API for flipping internal failure modes on and off), so nothing
here flips a hidden server-side switch — every fault is just a bad request
a real client could send.

```bash
BASE_URL=http://localhost ITERATIONS=50 ./fault-load.sh
```

Run both at once (different terminals) to see the 5xx-error-rate panel
move while the request-rate panel keeps climbing from the healthy traffic
underneath it — that contrast is the point.
