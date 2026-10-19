-- Tenant isolation with row-level security, for the /lakebase-t API.
--
-- Scenario: a supplier publishes one product catalog (public.products, from 01-catalog.sql) and each
-- customer (tenant) places and sees only its own orders. Each tenant reaches Postgres as its own managed
-- identity's role; RLS maps that role to a tenant through private.tenant_roles.
--
-- Schemas:
--   public   shared catalog. Tenants may read it; grants control it, not RLS.
--   app      tenant-owned data under RLS: orders, order_lines, order_totals (view). Exposed by the Data API.
--   private  tenants and the role-to-tenant mapping. Not exposed; tenant_for() is the only way in.
--
-- Run as the project owner, on the branch and in the database the Data API serves, after 01-catalog.sql
-- (order_lines references public.products). Replace <TENANT_A_MI_CLIENT_ID> and <TENANT_B_MI_CLIENT_ID> with
-- the managed identities' client IDs (scripts/10-postgres-setup.sh does this).
-- Re-running drops and recreates app and private (roles and their grants to authenticator are kept).

CREATE EXTENSION IF NOT EXISTS databricks_auth;

-- Roles must be created with databricks_create_role (not the UI) to be grantable to authenticator.
SELECT databricks_create_role('<TENANT_A_MI_CLIENT_ID>', 'SERVICE_PRINCIPAL')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '<TENANT_A_MI_CLIENT_ID>');
SELECT databricks_create_role('<TENANT_B_MI_CLIENT_ID>', 'SERVICE_PRINCIPAL')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '<TENANT_B_MI_CLIENT_ID>');
GRANT "<TENANT_A_MI_CLIENT_ID>" TO authenticator;
GRANT "<TENANT_B_MI_CLIENT_ID>" TO authenticator;

DROP SCHEMA IF EXISTS app CASCADE;
DROP SCHEMA IF EXISTS private CASCADE;
CREATE SCHEMA app;
CREATE SCHEMA private;

-- Tenants, and which Postgres role belongs to which tenant.
CREATE TABLE private.tenants (
    tenant_id text PRIMARY KEY,
    name      text NOT NULL
);
CREATE TABLE private.tenant_roles (
    role_name text PRIMARY KEY,   -- managed identity client ID
    tenant_id text NOT NULL REFERENCES private.tenants
);
INSERT INTO private.tenants VALUES
    ('a', 'Cafe chain'),
    ('b', 'Distributor');
INSERT INTO private.tenant_roles VALUES
    ('<TENANT_A_MI_CLIENT_ID>', 'a'),
    ('<TENANT_B_MI_CLIENT_ID>', 'b');

-- SECURITY DEFINER so tenant roles don't need access to tenant_roles. Inside it current_user is the owner,
-- so callers pass their own role in.
CREATE FUNCTION private.tenant_for(caller text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = private, pg_temp
    AS $$ SELECT tenant_id FROM private.tenant_roles WHERE role_name = caller $$;
REVOKE ALL ON FUNCTION private.tenant_for(text) FROM PUBLIC;

-- Every tenant-owned table carries tenant_id, defaulted to the caller's tenant so clients don't send it.
-- Keys lead with tenant_id: uniqueness is per tenant, and the primary key doubles as the tenant index.
CREATE TABLE app.orders (
    tenant_id  text NOT NULL DEFAULT private.tenant_for(current_user) REFERENCES private.tenants,
    id         bigint GENERATED ALWAYS AS IDENTITY,
    status     text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'submitted', 'shipped')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id)
);

-- Foreign-key checks ignore RLS. The composite key (tenant_id, order_id), with tenant_id fixed to the caller's
-- tenant by the default and the policy, means a line can only point at the caller's own order.
CREATE TABLE app.order_lines (
    tenant_id text   NOT NULL DEFAULT private.tenant_for(current_user),
    id        bigint GENERATED ALWAYS AS IDENTITY,
    order_id  bigint NOT NULL,
    sku       text   NOT NULL REFERENCES public.products (sku),
    qty       int    NOT NULL CHECK (qty > 0),
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, order_id) REFERENCES app.orders (tenant_id, id) ON DELETE CASCADE
);
CREATE INDEX ON app.order_lines (tenant_id, order_id);

-- security_invoker: the view runs with the caller's rights, so the RLS policies below apply to it. Without it the
-- view runs as its owner, and the Lakebase project owner has BYPASSRLS: every tenant would see every row.
CREATE VIEW app.order_totals WITH (security_invoker = true) AS
SELECT o.tenant_id,
       o.id                  AS order_id,
       o.status,
       count(l.id)           AS lines,
       coalesce(sum(l.qty * p.price), 0) AS total
  FROM app.orders o
  LEFT JOIN app.order_lines l ON l.tenant_id = o.tenant_id AND l.order_id = o.id
  LEFT JOIN public.products p ON p.sku = l.sku
 GROUP BY o.tenant_id, o.id, o.status;

-- Seed data. The project owner has BYPASSRLS, so RLS never applies to it (here or in psql later).
-- One row per INSERT so the fresh identity hands out order IDs 1-4 in this order.
INSERT INTO app.orders (tenant_id, status) VALUES ('a', 'submitted');  -- 1
INSERT INTO app.orders (tenant_id, status) VALUES ('a', 'open');       -- 2
INSERT INTO app.orders (tenant_id, status) VALUES ('b', 'shipped');    -- 3
INSERT INTO app.orders (tenant_id, status) VALUES ('b', 'open');       -- 4
INSERT INTO app.order_lines (tenant_id, order_id, sku, qty) VALUES
    ('a', 1, 'BEV-002', 12),
    ('a', 1, 'SNK-002', 6),
    ('a', 2, 'BEV-001', 4),
    ('b', 3, 'DRY-001', 20),
    ('b', 3, 'SNK-001', 30),
    ('b', 4, 'BEV-001', 10);

-- USING filters what a tenant can read, update and delete; WITH CHECK rejects writes into another tenant.
-- (SELECT ...) makes Postgres look the tenant up once per query instead of once per row.
-- FORCE applies the policies to a table owner without BYPASSRLS, for example if ownership moves to another role.
ALTER TABLE app.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.orders FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.orders
    USING (tenant_id = (SELECT private.tenant_for(current_user)))
    WITH CHECK (tenant_id = (SELECT private.tenant_for(current_user)));

ALTER TABLE app.order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.order_lines FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.order_lines
    USING (tenant_id = (SELECT private.tenant_for(current_user)))
    WITH CHECK (tenant_id = (SELECT private.tenant_for(current_user)));

-- Same grants for both tenants; RLS decides which rows each one sees. The catalog is read-only for tenants.
GRANT USAGE ON SCHEMA app, private, public TO "<TENANT_A_MI_CLIENT_ID>", "<TENANT_B_MI_CLIENT_ID>";
GRANT EXECUTE ON FUNCTION private.tenant_for(text) TO "<TENANT_A_MI_CLIENT_ID>", "<TENANT_B_MI_CLIENT_ID>";
GRANT SELECT, INSERT, UPDATE, DELETE ON app.orders, app.order_lines TO "<TENANT_A_MI_CLIENT_ID>", "<TENANT_B_MI_CLIENT_ID>";
GRANT SELECT ON app.order_totals, public.products TO "<TENANT_A_MI_CLIENT_ID>", "<TENANT_B_MI_CLIENT_ID>";

NOTIFY pgrst, 'reload schema';

-- Verify: one row per tenant, all true, resolved_tenant matching tenant_id.
SELECT r.role_name,
       r.tenant_id,
       t.name,
       pg_has_role('authenticator', r.role_name, 'MEMBER')                 AS authenticator_member,
       has_table_privilege(r.role_name, 'app.order_lines', 'INSERT')        AS can_write_lines,
       has_table_privilege(r.role_name, 'public.products', 'SELECT')        AS can_read_catalog,
       NOT has_table_privilege(r.role_name, 'public.products', 'UPDATE')    AS catalog_read_only,
       private.tenant_for(r.role_name)                                       AS resolved_tenant
  FROM private.tenant_roles r
  JOIN private.tenants t USING (tenant_id);
