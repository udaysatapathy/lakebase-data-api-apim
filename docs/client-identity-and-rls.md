# Client identity, Lakebase roles and row-level security

This guide covers how API clients authenticate to APIM, how that maps to the Postgres role Lakebase runs each request as, and what that means for row-level security (RLS). It builds on the token-exchange design in [README.md](../README.md).

## Two separate identities

A request crosses two trust boundaries, and each one has its own identity:

```
Client ──(Entra token, aud = your app registration)──> APIM ──(Databricks token for a managed identity)──> Lakebase Data API ──(SET ROLE "<MI client ID>")──> Postgres
         who is calling, and what may they do?                 which Postgres role runs the query?
```

- **Client identity** is checked only at APIM. The client gets an Entra token for an app registration you own (for example `api://lakebase-gateway`): client credentials for apps, authorization code for users. APIM validates the issuer, the audience and an app role or scope, then deletes the client's `Authorization` header.
- **Lakebase identity** is the APIM managed identity (MI). APIM exchanges the MI's Entra token for a Databricks token, and the Data API switches to the MI's Postgres role. The client's token never reaches Lakebase.

Two facts force this split:

- The Data API accepts only Databricks OAuth tokens. A client's Entra token is rejected with `400 {"message":"jwk not found"}`.
- The client can't exchange its own token for the MI's Databricks token, because the federation policy on the MI's service principal only matches the MI's object ID. Never add client apps to that policy: a client holding the MI's Databricks token can call the Data API directly and skip APIM.

## Recommended default: a few roles, defined by access level

Keep client identity separate from the Lakebase role (the "trusted subsystem" pattern). Map clients to a small, fixed set of roles by the access they need, never one role per client:

| Client app role (Entra) | Managed identity | Postgres role grants |
|---|---|---|
| `Lakebase.Read` | `id-lakebase-ro` | `SELECT` on exposed views |
| `Lakebase.Write` | `id-lakebase-rw` | `SELECT`/`INSERT`/`UPDATE`, `EXECUTE` on specific functions |

APIM reads the app role from the client's token and picks which MI's token to use. Each MI needs its own federation policy, Postgres role, `authenticator` grant and token cache key.

### Practices

1. **Postgres grants are the hard limit; APIM narrows within them.** If an APIM rule is wrong, Postgres still can't do more than the role allows. Give the read-only MI's role only `SELECT` rather than relying on APIM to block `POST`.
2. **Add a role when the access level differs, not when a client arrives.** Onboarding a client should mean assigning it an Entra app role, with no Postgres changes. If you find yourself creating a Postgres role per client, you need per-caller identity (see [Row-level security](#row-level-security)).
3. **Don't expose raw tables.** Put views and functions in a dedicated schema, grant on those, and list only that schema in the Data API's exposed schemas. Writes with business rules go through functions (like `adjust_stock()` in the demo), not open `PATCH` on tables.
4. **Make APIM the only way in.** Only APIM's MI can get the Databricks token through the federation policy. Keep it that way: no OAuth secrets on that service principal (turn off `enable_secret_alternative` unless you use `/lakebase-s`, which puts one there) and no client apps on the federation policy.
5. **Keep audit traceable in APIM.** Postgres sees one role per MI, so per-client audit lives in APIM: log the caller's Entra `oid`, `appid`/`azp` and the APIM request ID. The Data API doesn't propagate trace headers (`X-Request-Id` and custom trace headers are "not applicable"), so correlate with Lakebase by role and time.
6. **Have a kill switch at each layer.**
    - One client: remove its app role or APIM subscription.
    - Every client of one MI: `REVOKE "<mi-client-id>" FROM authenticator` takes effect immediately.
    - Removing the federation policy also works, but only once the cached token expires (up to about 55 minutes).
7. **Subscription keys are optional.** With token validation in place, keep keys for metering and quotas or turn them off.

## Row-level security

The Data API supports Postgres RLS ([docs](https://learn.microsoft.com/en-us/azure/databricks/oltp/projects/data-api)). The `authenticator` role assumes the caller's role for each request, so policies see that role as `current_user`: a user's email, or a service principal's client ID.

### What RLS can key on

RLS can only tell apart **Postgres roles**. The Data API offers no other way to get caller identity into SQL:

- Application settings (GUCs) are not supported, so you can't set something like `app.app_role` per request.
- The `db-pre-request` function is not supported, so nothing can run per request to read claims.
- JWT configuration is "not applicable", so there are no `request.jwt.claims`.

So **APIM can't pass the caller's identity to Postgres in a header or claim.** With one MI for every client, all requests share one `current_user`, and RLS sees a single caller. RLS only does something here when different callers arrive as different Postgres roles.

### Option A: one MI per app role (keeps the gateway pattern)

Each app role (a group of clients, such as one customer or business unit) gets its own MI, Postgres role and group role. APIM maps the client's app role to that app role's MI. RLS then isolates rows by group role.

```
Client (app role A) ──> APIM ──(Databricks token for id-app-role-a)──> Data API ──(SET ROLE "<id-app-role-a client ID>")──> RLS: owner_role = 'orders_app_role_a'
Client (app role B) ──> APIM ──(Databricks token for id-app-role-b)──> Data API ──(SET ROLE "<id-app-role-b client ID>")──> RLS: owner_role = 'orders_app_role_b'
```

Each app role gets one `NOLOGIN` group role, and the app role's MI role is its only member. Grants go to the group role, and the member inherits them. Every row records its group role in `owner_role`, which defaults to `private.owner_role()`. That function returns the caller's group role, found in `pg_auth_members`, so no mapping table or `SECURITY DEFINER` function is needed. It returns NULL if the caller belongs to more than one group role, which matches no rows.

```sql
CREATE SCHEMA private;                                   -- not in the Data API's exposed schemas

CREATE FUNCTION private.owner_role() RETURNS text
  LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
  AS $$
    SELECT CASE WHEN count(*) = 1 THEN min(g.rolname) END
      FROM pg_auth_members m
      JOIN pg_roles g ON g.oid = m.roleid
      JOIN pg_roles u ON u.oid = m.member
     WHERE u.rolname = current_user
       AND g.rolname LIKE 'orders\_app\_role\_%'
  $$;
REVOKE ALL ON FUNCTION private.owner_role() FROM PUBLIC;

-- Per app role: the MI's role, its authenticator grant, a group role, and the membership.
SELECT databricks_create_role('<app-role-a-mi-client-id>', 'SERVICE_PRINCIPAL');
GRANT "<app-role-a-mi-client-id>" TO authenticator;
CREATE ROLE orders_app_role_a NOLOGIN;
GRANT orders_app_role_a TO "<app-role-a-mi-client-id>";

CREATE TABLE api.orders (
  owner_role text NOT NULL DEFAULT private.owner_role(),
  id         bigint GENERATED ALWAYS AS IDENTITY,
  PRIMARY KEY (owner_role, id)
);

ALTER TABLE api.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE api.orders FORCE ROW LEVEL SECURITY;         -- also applies to the table owner
CREATE POLICY owner_role_isolation ON api.orders
  USING (owner_role = (SELECT private.owner_role()))
  WITH CHECK (owner_role = (SELECT private.owner_role()));   -- blocks writing rows into another app role

-- Grants go to the group roles, and their members inherit them.
GRANT USAGE ON SCHEMA api, private TO orders_app_role_a;
GRANT EXECUTE ON FUNCTION private.owner_role() TO orders_app_role_a;
GRANT SELECT, INSERT, UPDATE ON api.orders TO orders_app_role_a;
```

`private` isn't an exposed schema, so Data API callers can't call `owner_role()` directly. It always reads `current_user`, which callers can't change, and the default fills `owner_role` from it, so a caller can't choose another group role.

APIM side: read the client's app role (such as `Orders.AppRoleA`) and map it to that app role's MI. Each app role needs its own `authentication-managed-identity` call (one `choose` branch per MI) and its own cache key (`lakebase-dbx-token-app-role-<x>`), so one app role's token is never served to another. The APIM instance needs every app role's MI attached.

Fits: tens of app roles, with onboarding an app role as an infrastructure change (app role, MI, federation policy, Postgres group role and membership, policy branch). Doesn't fit: thousands of app roles, or isolation per end user.

This repo deploys Option A as the `/lakebase-rls` API: see the [README](../README.md).

### Option B: per-user identity (end-to-end)

Each caller reaches Postgres as themselves (`current_user` = their email), so policies such as `USING (assigned_to = current_user)` work as written. This replaces the gateway pattern rather than extending it:

- Every caller needs a Databricks identity in the workspace and a Postgres role created with `databricks_create_role(..., 'USER')` and granted to `authenticator`.
- The caller's Entra token has to become a Databricks token for that user, through token exchange with an account-level federation policy, done by the client or by APIM per caller (one cache entry per user).
- APIM becomes an ordinary proxy (rate limits, routing). It no longer decides what callers may do.

This repo covers token exchange for managed identities only. Check the exchange for user tokens in your own setup before relying on Option B.

### Choosing

| Need | Use |
|---|---|
| Access levels differ (read vs write), no row isolation | Default: one MI per access level, no RLS |
| Rows isolated per app role, tens of app roles | Option A: one MI per app role + RLS on the caller's group role |
| Rows isolated per end user, or database audit per person | Option B: per-user identity + RLS on `current_user` |
| Row isolation enforced by APIM only, Postgres trusts APIM fully | Not possible: the Data API has no way to pass caller identity to SQL |

### RLS gotchas

- **Views bypass RLS by default.** A view runs with its owner's privileges, so RLS on the base table is evaluated as the owner. Create views with `WITH (security_invoker = true)` (Postgres 15+) so policies apply to the caller's role. This matters because the default practice above exposes views, not tables.
- **Table owners bypass RLS** unless the table has `FORCE ROW LEVEL SECURITY`. Don't let the MI roles own the tables they query.
- **`SECURITY DEFINER` functions bypass RLS** for the tables they touch, because they run as their owner. Use them deliberately and pass the caller's role in explicitly; inside them `current_user` is the owner, not the caller. The app role design needs none: `private.owner_role()` is a plain SQL function that reads `pg_auth_members`, which every role can read.
- **Writes need `WITH CHECK`.** `USING` filters rows a caller can see or change; `WITH CHECK` stops inserts and updates that would create rows for another app role.
- **A table with RLS enabled and no policy returns no rows** (deny by default). Expect empty `200` responses, not `403`, while setting up.
- **Roles are per branch.** Create roles, group roles and policies on the branch that serves the Data API.
