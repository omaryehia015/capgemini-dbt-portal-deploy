# Semantic layer: dbt + Cube, and using it from BI and AI tools

The portal runs [Cube](https://cube.dev) (open-source Cube Core) as a managed
semantic layer on top of the client's dbt project. This page explains how dbt
and Cube work together, what the portal generates, and how tools outside the
portal (BI, notebooks, AI agents) use the same metrics. The Semantic Layer
page has the same guidance in its **How it works** panel (header button) and
its **Connect tools** tab. Its three tabs: **Overview**, **Explore & query**
(browse the model and query it side by side) and **Connect tools**.

## Why both

| | dbt | Cube |
|---|---|---|
| Job | Build tested, documented tables (marts) in the warehouse | Define business measures, dimensions and joins once, and serve them |
| Output | Tables and views, `manifest.json`, `catalog.json` | REST, GraphQL and a Postgres-compatible SQL API, caching, pre-aggregations |
| Who changes it | Analytics engineers, in pull requests | Generated from dbt; business logic added in the dbt repo's `cube/` folder |

dbt answers "is this data right?"; Cube answers "what does *revenue* mean, and
does every tool get the same number?". The portal connects them so nothing is
typed twice.

## Lifecycle

```mermaid
flowchart LR
  A["dbt build<br/>tables in the warehouse"] --> B["manifest.json + catalog.json<br/>(dbt docs generate)"]
  B --> C["Portal: Generate<br/>one cube per model"]
  H[/"dbt repo cube/ folder<br/>views, extra measures"/] --> C
  C --> D["Cube compiles<br/>(within one poll, ~5 s)"]
  D --> E["Semantic page · Ask AI's Data Analyst"]
  D --> G["AI agents: Claude, Copilot, Cursor<br/>(the portal's MCP server)"]
  D --> F["BI tools · notebooks<br/>(SQL API, optional)"]
  A -. "successful dbt job,<br/>newer manifest" .-> C
```

1. **dbt builds the marts** (dbt Runner, a schedule or CI).
2. **dbt describes them**: `target/manifest.json` (models, tests, descriptions)
   and `target/catalog.json` (column types, from `dbt docs generate`).
3. **The portal generates the Cube model** from the dbt folders picked on the
   Semantic Layer page (marts are pre-selected). Generated files go to the
   backend's state directory (`<PORTAL_DATA_DIR>/cube/model/generated/`), the
   dbt repo's `cube/` folder is copied next to them (`custom/`).
4. **Cube compiles it.** `cube.js` polls the backend's `/internal/cube/state`;
   a new model version is live within one poll, no restart.
5. **Everything reads the same definitions**: the page's explorer and query
   builder, Ask AI's Data Analyst, AI agents over the portal's MCP server, and,
   if published, BI tools over the SQL API.

After the first Generate, a successful dbt job that writes a newer
`manifest.json` regenerates the model with the same folders
(`CUBE_AUTO_REGENERATE=true`, the default).

## Which warehouses

The semantic engine connects to **Snowflake, PostgreSQL, Redshift and
BigQuery** (backend `warehouse_profile.SUPPORTED`; the cube image keeps only
their drivers). **Databricks is not supported yet**: Cube's Databricks driver
needs a JDK and a JDBC driver the image leaves out. On a Databricks project the
pages say so instead of offering a setup that cannot succeed (the setup strip,
the semantic layer's connect tab, Ask AI's connection bar), Ask AI's Data
Analyst answers with SQL on the dbt models, and the MCP server's tools reply
that there is no governed model. Every visual names the warehouse from the
semantic layer's login, else from the dbt project (`/api/semantic/status` and
`/api/ask-ai/semantic` report the platform and whether the engine supports it).

## What is generated from dbt

| In dbt | In Cube |
|---|---|
| Model (table, view, incremental) in a selected folder | Cube with `sql_table` = the manifest's `relation_name`. Ephemeral, disabled and installed-package models are skipped |
| Column + type (`catalog.json`, else `data_type` in YAML) | Dimension: `string`, `number`, `time` or `boolean`. JSON/array/struct columns are left for hand-written dimensions |
| Model and column descriptions | Cube and member descriptions (shown to BI tools and AI agents) |
| `unique` test or `primary_key` constraint (else an `id` / `<model>_id` column) | `primary_key: true` (correct counts across joins) |
| `relationships` test | `many_to_one` join to the referenced model |
| Numeric columns (optional) | `sum_<col>` for quantities, `average_<col>` for rates/prices/scores, `lowest_`/`highest_` for `min_`/`max_` columns, plus `count` per cube |
| `updated_at`, `_loaded_at` and similar | `refresh_key`: `SELECT MAX(col)` every minute, so caches drop when dbt changes the data |

Example. What the team already writes:

```yaml
# models/marts/_marts.yml
models:
  - name: fct_orders
    description: One row per order.
    columns:
      - name: order_id
        tests: [unique, not_null]          # -> primary key
      - name: customer_id
        tests:
          - relationships: { to: ref('dim_customers'), field: customer_id }   # -> join
      - name: amount
        description: Order value in EUR.
      - name: updated_at                   # -> refresh key
```

What the portal generates (never edit it; regeneration overwrites it):

```yaml
cubes:
  - name: fct_orders
    sql_table: ANALYTICS.MARTS.FCT_ORDERS
    description: One row per order.
    refresh_key: { sql: SELECT MAX(updated_at) FROM ANALYTICS.MARTS.FCT_ORDERS, every: 1 minute }
    joins:
      - { name: dim_customers, relationship: many_to_one, sql: "{CUBE}.customer_id = {dim_customers}.customer_id" }
    dimensions:
      - { name: order_id, type: number, primary_key: true, public: true }
      - { name: customer_id, type: number }
      - { name: amount, type: number, description: Order value in EUR. }
      - { name: updated_at, type: time }
    measures:
      - { name: count, type: count }
      - { name: sum_amount, type: sum, sql: "{CUBE}.amount", title: Total amount }
```

## Business logic: the dbt repo's `cube/` folder

Hand-written YAML (or JS) in `<dbt project>/cube/` is versioned and reviewed
with the dbt code and survives every regeneration:

- **Views**: the curated interface. One view per business question, joins
  worked out once, members grouped in folders. BI users and AI agents should
  query views, not cubes.
- **Extra measures**: `extends: fct_orders` in a new cube, then add measures
  such as `average_order_value` or filtered counts.
- **Pre-aggregations**: rollups for questions asked every day
  (`external: false` builds them in the warehouse; no Cube Store needed).
- **Hide raw cubes** with `public: false` once views cover them.

## Using the semantic layer outside the portal

| Consumer | Way in | Status |
|---|---|---|
| Business users in the portal | Semantic Layer page (explore, query, CSV) | Built in |
| Plain-language questions | Ask AI's **Data Analyst** answers through the semantic layer | Built in |
| AI assistants and agents (Claude, Copilot, Cursor, custom) | The portal's **MCP server**, `/api/semantic/mcp` | Built in, below |
| Power BI, Tableau, Excel, Superset, Metabase | Cube **SQL API** (Postgres protocol) | Built in, below |
| Python, notebooks, JDBC/ODBC apps | SQL API with any Postgres driver | Built in, below |

Cube's REST API stays internal: its tokens are signed with `CUBE_API_SECRET`,
the portal's own key to Cube. Never give that secret to a tool.

### Getting a personal key (each user, one click)

Nobody shares a password and no administrator hands one out. On the Semantic
Layer page, **Connect tools → Create my key**:

- One key per user, a random token shown once. It is the **password** of the
  user's SQL login (the login is their portal username) and the **bearer token**
  of the MCP server. The tab shows it with a ready connection string, Python
  snippet and MCP configs.
- Only a SHA-256 of it is stored (backend `CUBE_STATE_DIR/sql_logins.json`).
- Cube's `checkSqlAuth` (cube repo `cube.js`) asks the backend
  (`POST /internal/cube/sql-auth`) on every new connection, and the MCP server
  checks every request, so the key works only while the user is active and has
  `observability.view`. A new key replaces the old one at once for both;
  **Delete** revokes it. Both are in the audit trail.

How the pieces fit:

```mermaid
sequenceDiagram
  participant U as User (portal)
  participant B as Backend (semantic)
  participant T as BI tool / agent
  participant C as Cube SQL API :15432
  participant A as AI agent (MCP)
  U->>B: POST /api/semantic/sql-access
  B-->>U: personal key (shown once)
  T->>C: connect user/key (Postgres protocol)
  C->>B: POST /internal/cube/sql-auth (cube token)
  B-->>C: 200 {username} or 401
  C-->>T: rows, built from the semantic model
  A->>B: POST /api/semantic/mcp (Authorization: Bearer key)
  B->>B: key -> user, active, observability.view, environment
  B-->>A: JSON-RPC result (tools run through Cube's REST API)
```

### What the platform team does

Nothing, in the standard install: the cube image listens on 15432
(`CUBEJS_PG_SQL_PORT`) and `compose.yaml` publishes it as `CUBE_SQL_PORT`
(default 15432). Optional settings in `.env`:

```bash
CUBE_SQL_PORT=15432          # the host port BI tools use
CUBE_SQL_HOST=bi.example.com # when BI tools reach the host under another name
```

Kubernetes: the cube Service has a `sql` port (15432) inside the cluster. For
tools outside the cluster, expose it with an internal load balancer and set
`CUBE_SQL_HOST` / `CUBE_SQL_PORT` on the backend to that address.

Security notes:

- The SQL API is read-only: it answers queries over the model and never writes.
- A login sees every **public** cube and view. Publish views and hide raw cubes.
- Keep the port on the internal network or VPN, like the portal itself, or
  behind a TLS-terminating proxy. Passwords are 32-byte random tokens.

### BI tools

Connect as to a PostgreSQL database with the details on the Connect tools tab:
host = the portal host, port 15432, database `cube` (any name works), your
portal username and your personal key as the password.

| Tool | Connector and mode |
|---|---|
| Power BI | PostgreSQL database, **DirectQuery** (numbers stay governed; don't re-aggregate measures in DAX) |
| Tableau | PostgreSQL, **Live** connection |
| Excel | PostgreSQL ODBC driver (psqlODBC) DSN, then Get Data → From ODBC |
| Superset / Metabase | PostgreSQL database, `postgresql://<username>:<password>@host:15432/cube` |

Queries use `MEASURE()` for measures and group by dimensions; Cube writes the
joins and aggregation:

```sql
SELECT DATE_TRUNC('month', order_date) AS month, status, MEASURE(sum_amount) AS revenue
FROM sales                -- a view
GROUP BY 1, 2
ORDER BY revenue DESC;
```

### Notebooks and apps

```python
import os, pandas as pd, psycopg
with psycopg.connect(host="portal-host", port=15432, dbname="cube",
                     user="<username>", password=os.environ["PORTAL_SQL_PASSWORD"]) as conn:
    df = pd.read_sql("SELECT status, MEASURE(count) AS orders FROM sales GROUP BY 1", conn)
```

### AI assistants and agents (MCP)

The portal is an MCP server for its semantic layer. Agents connect to
`https://<portal>/api/semantic/mcp` with the user's personal key and get the
same tools as Ask AI's Data Analyst (backend `app/services/semantic_tools.py`):

| Tool | What it does |
|---|---|
| `semantic_overview` | Every view and cube with its measures, dimensions and segments (views first) |
| `semantic_model` | Member details and descriptions, by cube name or search words |
| `semantic_query` | A query in Cube's REST format; Cube writes the SQL, joins and aggregation. Returns columns, up to 200 rows and the generated SQL |

- **Transport**: MCP Streamable HTTP, stateless: one JSON-RPC request per
  `POST`, answered with JSON (`GET` answers 405, there is no session). Protocol
  versions 2024-11-05 to 2025-11-25.
- **Authentication**: `Authorization: Bearer <personal key>`. The agent acts as
  the user: it works while the account is active and has `observability.view`,
  and stops the moment the key is replaced or deleted.
- **Environment**: the default one; add `X-Portal-Env: <slug>` to read another
  (the user's role must be allowed to open it). The page writes it into the
  snippets when the portal has several environments.
- **Audit**: every `semantic_query` is logged as `SEMANTIC_MCP`, with the Cube
  query and the user.
- **Network**: it is a route of the semantic service behind the portal's own
  gateway (`/api/semantic`), so no port or setting is added.

Client configuration (the Connect tools tab fills in the URL and key, and
has a **Test the connection** button that calls the server as an agent does):

```bash
# Claude Code
claude mcp add --transport http semantic-layer https://<portal>/api/semantic/mcp \
  --header "Authorization: Bearer <key>"
```

```jsonc
// Cursor: ~/.cursor/mcp.json
{ "mcpServers": { "semantic-layer": { "url": "https://<portal>/api/semantic/mcp",
  "headers": { "Authorization": "Bearer <key>" } } } }

// VS Code / GitHub Copilot: .vscode/mcp.json (VS Code asks for the key once)
{ "inputs": [{ "type": "promptString", "id": "semantic-layer-key", "password": true,
               "description": "Semantic layer personal key" }],
  "servers": { "semantic-layer": { "type": "http", "url": "https://<portal>/api/semantic/mcp",
    "headers": { "Authorization": "Bearer ${input:semantic-layer-key}" } } } }

// Claude Desktop: claude_desktop_config.json, through the mcp-remote bridge
{ "mcpServers": { "semantic-layer": { "command": "npx",
  "args": ["-y", "mcp-remote", "https://<portal>/api/semantic/mcp", "--header", "Authorization:${AUTH_HEADER}"],
  "env": { "AUTH_HEADER": "Bearer <key>" } } } }
```

Other options:

| Option | Fit for the portal |
|---|---|
| **The portal's MCP server** | **Recommended**: governed tools, the user's own key and permissions, audited |
| Postgres MCP server on the SQL API | Works with the same key as the SQL password; the agent sees views and measures as tables. Cube emulates only part of Postgres's catalog (no index advice or `pg_stat_statements`) |
| Cube's official MCP server | Cube Cloud only (hosted endpoint with OAuth, Premium/Enterprise plans). Not available for the self-hosted Cube Core the portal runs |
| Community Cube MCP servers on the REST API | Not recommended: they need `CUBE_API_SECRET` |
