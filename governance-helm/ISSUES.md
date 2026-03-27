# Issues Encountered During Governance Proxy Deployment & Testing

This document catalogues every issue encountered while deploying and testing the AI Governance Proxy Helm chart on AWS EKS.

---

## Issue 1: Docker Image Platform Mismatch (`ErrImagePull`)

**Symptom:** The `ai-governance-proxy` pod failed to pull the image with:
```
no match for platform in manifest: not found
```

**Root Cause:** The Docker image was built on an Apple Silicon Mac (ARM64/linux/arm64) but the EKS worker nodes are AMD64 (linux/amd64). Docker builds default to the host architecture.

**Fix:** Rebuilt the image using `docker buildx` with explicit multi-platform targeting:
```bash
docker buildx create --name multiarch --use
docker buildx build --builder multiarch --platform linux/amd64 \
  -t anuddeeph/ai-governance-proxy:v1 --push .
```

**Lesson:** Always build multi-arch images when targeting cloud Kubernetes clusters from Apple Silicon development machines.

---

## Issue 2: PersistentVolumeClaim Stuck in `Pending`

**Symptom:** PostgreSQL and Redis StatefulSet pods stuck in `Pending` because PVCs could not be provisioned.

**Root Cause:** The EKS cluster had a `gp2` StorageClass but it was **not marked as default**. Helm charts that don't specify `storageClassName` need a default StorageClass.

**Fix:** Created a `gp3` StorageClass and marked it as default:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
```

Then deleted the stuck PVCs and let them recreate with the new default.

**Lesson:** Always verify a default StorageClass exists on a fresh EKS cluster before deploying stateful workloads.

---

## Issue 3: First Postgres MCP Image — Host Header Validation (`421 Misdirected Request`)

**Symptom:** The first Postgres MCP image (`openmcpserver/mcp-postgres:latest`) returned `421 Misdirected Request` with "Invalid Host header" for every request routed through the Kubernetes Service.

**Root Cause:** The `openmcpserver/mcp-postgres` image uses uvicorn with Starlette's `TrustedHostMiddleware` which validates the HTTP `Host` header. When requests come through a Kubernetes Service (e.g., `postgres-mcp:8080`), the Host header doesn't match the container's expected localhost value.

**Fix:** Switched to `crystaldba/postgres-mcp:latest` which does not perform Host header validation and supports SSE transport via the `--transport sse` flag.

**Lesson:** Not all MCP server images are designed for Kubernetes service networking. Test connectivity through the Service before integrating.

---

## Issue 4: Postgres MCP Running in stdio Mode (Not SSE)

**Symptom:** The `crystaldba/postgres-mcp` container started, connected to PostgreSQL successfully, but no ports were listening. `netstat -tlnp` inside the container showed zero listening sockets.

**Root Cause:** The image defaults to **stdio transport** (designed for subprocess execution), not SSE. Without the `--transport sse` flag, it reads from stdin and writes to stdout instead of running an HTTP server.

**Fix:** Added command-line arguments in the Helm template:
```yaml
args:
  - "--transport"
  - "sse"
  - "--sse-port"
  - "8000"
```

The entrypoint script auto-detects SSE transport and adds `--sse-host=0.0.0.0`.

**Lesson:** Always check MCP server images for their transport mode. Most images default to stdio for use with desktop MCP clients; Kubernetes deployments need SSE or streamable-HTTP.

---

## Issue 5: Datasource SSE URL Missing `/sse` Path

**Symptom:** The governance proxy logged:
```
failed to list tools from datasource — it will not appear in tools/list
error: starting SSE client: unexpected status code: 404
```

**Root Cause:** The proxy's SSE client connects to the URL exactly as configured. The Helm template generated URLs like `http://postgres-mcp:8000` (no path), but `crystaldba/postgres-mcp` serves SSE at `/sse`. The proxy's MCP SDK requires the full SSE endpoint URL including the path.

**Fix:** Appended `/sse` to all datasource URLs in both the configmap template and the helpers template:
```go
// Before
printf "http://postgres-mcp:%d" (.Values.postgres.mcp.port | int)
// After
printf "http://postgres-mcp:%d/sse" (.Values.postgres.mcp.port | int)
```

This fix was needed in **four places**: datasource URLs (2) and toolCache server URLs (2) — both in `proxy-configmap.yaml` inline templates and `_helpers.tpl`.

**Lesson:** The proxy configmap template had duplicated URL generation logic (inline and in helpers). The helpers were unused. Both needed to be fixed.

---

## Issue 6: Proxy Starts Before MCP Backend (Race Condition)

**Symptom:** The proxy logged `failed to list tools from datasource — connection refused` even though the postgres-mcp pod was healthy.

**Root Cause:** The governance proxy connects to all datasources at startup and does not retry. If the MCP backend pod starts slower than the proxy, the connection attempt fails and the datasource is skipped entirely.

**Fix:** Restarted the proxy deployment after confirming the MCP backend was ready:
```bash
kubectl rollout restart deployment/governance-governance-helm -n governance
```

**Lesson:** Consider adding an `initContainer` that waits for the MCP backend to be ready, or add retry logic to the proxy's datasource connection.

---

## Issue 7: SSE Connection to Backend Goes Stale

**Symptom:** Tool calls that worked initially started timing out with:
```
forward failed: transport error: timeout waiting for SSE response after 1m0s
```

**Root Cause:** The proxy maintains a single persistent SSE connection to each backend MCP server (pooled by URL in `internal/forward/forwarder.go`). The `crystaldba/postgres-mcp` backend closes its SSE stream after delivering a response, but the proxy's `mcp-go` SSE client doesn't detect the dead connection until the next `CallTool` hits the library's hardcoded 60-second response timeout.

**Initial Workaround:** Restart the proxy deployment to establish fresh SSE connections:
```bash
kubectl rollout restart deployment/governance-governance-helm -n governance
```

**Permanent Fix (branch `fix/sse-client-evict-retry`):** Three changes to `internal/forward/forwarder.go`:

1. **15-second first-call timeout** — The initial `CallTool` attempt uses a short `context.WithTimeout(ctx, 15s)` instead of the mcp-go default of 60s. This detects stale connections fast.

2. **Compare-and-swap eviction** (`compareAndEvictSSEClient`) — On failure, only the specific stale client pointer is evicted from the pool. This prevents a race condition where concurrent goroutines (all holding the same stale client) could evict each other's fresh reconnections.

3. **Automatic retry** — After evicting the dead client, a fresh SSE connection is established via `getOrCreateClient` and the tool call is retried with the full parent context deadline.

```go
// First attempt with short timeout to detect stale connections fast.
firstCtx, firstCancel := context.WithTimeout(ctx, sseFirstCallTimeout)
result, err := mcpClient.CallTool(firstCtx, req)
firstCancel()

if err != nil {
    // Evict only if the pool still holds this exact stale client.
    f.compareAndEvictSSEClient(call.TargetURL, mcpClient)
    // Reconnect and retry...
    mcpClient, err = f.getOrCreateClient(ctx, call.TargetURL)
    result, err = mcpClient.CallTool(ctx, req)
}
```

**Race condition detail:** Without compare-and-swap, if Call B and Call C both hold the same stale client and both timeout simultaneously, Call B evicts and reconnects (creating Client-2), then Call C evicts Client-2 (thinking it's stale) and creates Client-3. Call B's retry then fails on the now-closed Client-2. The CAS check `c == staleClient` ensures Call C sees that the pool already has a new client and skips eviction.

**Lesson:** Long-lived SSE connections in Kubernetes are fragile. Backend pod restarts, service IP changes, or network timeouts can silently break them. Pooled SSE clients need evict-and-retry logic with compare-and-swap to be safe under concurrent access.

---

## Issue 8: Web UI Returning 404

**Symptom:** Navigating to `http://localhost:8081/ui` returned `404 page not found`.

**Root Cause:** The proxy code (`internal/proxy/pipeline.go`, line 547) conditionally registers UI routes only when **both** `ui.enabled=true` AND `ui.passwordHash` is non-empty. The initial `values.yaml` had `passwordHash: ""`.

**Fix:** Generated a bcrypt hash for the admin password and set it in values:
```yaml
ui:
  enabled: true
  passwordHash: "$2a$10$PxXvXkW4i10fMWMXF.CINeA13V5RfoQTsAzGoKWyr2lLnhZvRPkPG"
```

**Lesson:** The UI requires a password hash to be configured — it's a security gate, not just a feature flag. Document this requirement clearly.

---

## Issue 9: Web UI Login "Invalid Credentials" with Python bcrypt Hash

**Symptom:** After fixing the 404, the UI login form returned "invalid credentials" when logging in with admin/admin123. Strangely, `curl` to the same `/api/v1/ui/login` endpoint succeeded.

**Root Cause:** The initial bcrypt hash was generated with Python's `bcrypt` library which produces `$2b$` prefix hashes. While Go's `golang.org/x/crypto/bcrypt` library can technically verify `$2b$` hashes, there was a subtle incompatibility in how the hash was parsed through the Helm → ConfigMap → YAML → Go pipeline.

**Fix:** Generated the hash directly using Go's bcrypt library:
```go
import "golang.org/x/crypto/bcrypt"
hash, _ := bcrypt.GenerateFromPassword([]byte("admin123"), 10)
// Produces: $2a$10$PxXvXkW4i10fMWMXF.CINeA13V5RfoQTsAzGoKWyr2lLnhZvRPkPG
```

**Lesson:** Always use the same language's bcrypt implementation that the application uses. Go expects `$2a$` hashes. Don't mix Python bcrypt (`$2b$`) with Go verification.

---

## Issue 10: Policy Argument Key Mismatch (`query` vs `sql`)

**Symptom:** All policies that checked SQL content (DDL, PII, writes) failed to match — tool calls passed through without policy enforcement.

**Root Cause:** The policies were written to check `object.tool.arguments["query"]`, but the `crystaldba/postgres-mcp` image uses `sql` as the argument key (not `query`). The tools/list response showed: `"inputSchema": {"properties": {"sql": {"type": "string"}}}`.

**Fix:** Updated all six policies to use `arguments["sql"]` instead of `arguments["query"]`:
```yaml
# Before
object.tool.arguments.exists(k, k == "query") &&
object.tool.arguments["query"].upperAscii().startsWith("SELECT")

# After
object.tool.arguments.exists(k, k == "sql") &&
object.tool.arguments["sql"].upperAscii().startsWith("SELECT")
```

**Lesson:** Always inspect the actual MCP server's `tools/list` response to verify argument names before writing policies. Different MCP servers use different argument keys for the same logical operation.

---

## Issue 11: Policy Evaluation Order — Audit Overriding Require-Approval

**Symptom:** INSERT statements were being forwarded to the backend instead of entering the HITL approval queue.

**Root Cause:** Policies are evaluated in **alphabetical filename order**. `audit-writes.yaml` (enforcement-mode: audit) loaded before `require-approval-writes.yaml`. The proxy returns on the **first non-allow decision**, so the audit policy matched first and allowed the request through (audit mode permits execution but logs a violation). The require-approval policy was never evaluated.

**Fix:** Renamed the audit policy file from `audit-writes.yaml` to `z-audit-writes.yaml` so it loads after all `require-*` policies:
```yaml
# Before: audit-writes.yaml (loads first alphabetically)
# After:  z-audit-writes.yaml (loads last)
```

**Lesson:** Policy evaluation order is determined by filename sort order. When multiple policies match the same tool call, the first non-allow decision wins. Name files strategically — use prefixes like `01-`, `02-` or `z-` to control ordering.

---

## Issue 12: Tool Cache Not Working for `execute_sql`

**Symptom:** Repeated identical SELECT queries always went to the backend — no cache hits recorded in metrics.

**Root Cause:** The `toolCache.tools` configuration listed old tool names (`execute_read`, `list_tables`, `describe_table`) that didn't exist in the `crystaldba/postgres-mcp` server. The `defaultTTLSeconds` was set to `0` (no caching), so unlisted tools like `execute_sql` were never cached.

**Fix:** Updated the cache configuration with the actual tool names from `crystaldba/postgres-mcp`:
```yaml
toolCache:
  defaultTTLSeconds: 30
  tools:
    - name: list_schemas
      ttlSeconds: 300
    - name: list_objects
      ttlSeconds: 300
    - name: execute_sql
      ttlSeconds: 30
```

**Lesson:** Cache configuration must match the actual tool names exposed by the MCP server. After changing MCP server images, always update the cache configuration to match.

---

## Issue 13: SSE Eviction Race Condition Under Concurrent Tool Calls

**Symptom:** After adding basic evict-and-retry logic (first iteration of the fix), concurrent tool calls still failed with:
```
tool call to http://postgres-mcp:8000/sse failed after reconnect: transport error: connection has been closed
```

**Root Cause:** Multiple goroutines handling concurrent tool calls (e.g., cache test Call B and Call C) all held the same stale SSE client pointer. When both calls timed out simultaneously:
1. Call B evicted the stale client and created a fresh Client-2 in the pool
2. Call C also tried to evict — but the pool now contained Client-2 (not the stale one)
3. Call C's eviction closed Client-2 and created Client-3
4. Call B's retry on Client-2 failed because Call C had already closed it

**Fix:** Replaced blind `evictSSEClient(url)` with `compareAndEvictSSEClient(url, staleClient)` that checks the pointer identity:
```go
func (f *mcpForwarder) compareAndEvictSSEClient(serverURL string, staleClient *client.Client) bool {
    f.mu.Lock()
    defer f.mu.Unlock()
    if c, ok := f.clients[serverURL]; ok && c == staleClient {
        _ = c.Close()
        delete(f.clients, serverURL)
        return true
    }
    return false  // Another goroutine already reconnected — use their client
}
```

When Call C tries to evict, it sees the pool holds Client-2 (not the stale client it failed on), so it skips eviction and picks up Call B's fresh client via `getOrCreateClient`.

**Lesson:** Any pooled resource that supports evict-and-recreate must use compare-and-swap semantics to prevent concurrent evictors from destroying each other's fresh connections. This is the same pattern as Go's `sync.Pool` or Java's `ConcurrentHashMap.replace`.

---

## Summary

| # | Issue | Category | Severity |
|---|-------|----------|----------|
| 1 | ARM64 image on AMD64 nodes | Build/Deploy | Critical |
| 2 | No default StorageClass | Infrastructure | Critical |
| 3 | Host header validation in MCP image | Networking | Critical |
| 4 | MCP server running in stdio mode | Configuration | Critical |
| 5 | Missing `/sse` path in datasource URL | Configuration | Critical |
| 6 | Proxy starts before MCP backend | Race Condition | High |
| 7 | SSE connection goes stale (+ permanent fix) | Reliability | Critical |
| 8 | UI 404 when passwordHash is empty | Configuration | Medium |
| 9 | Python bcrypt hash incompatible with Go | Compatibility | Medium |
| 10 | Policy argument key mismatch | Policy Authoring | High |
| 11 | Policy evaluation order conflict | Policy Authoring | High |
| 12 | Cache misconfigured for actual tools | Configuration | Medium |
| 13 | SSE eviction race condition (concurrent calls) | Concurrency | High |
