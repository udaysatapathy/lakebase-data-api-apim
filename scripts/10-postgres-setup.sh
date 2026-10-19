#!/usr/bin/env bash
# Create the catalog, the Postgres roles for the managed identities and, with per-tenant access, the tenant schema
# with row-level security. Then refresh the Data API's schema cache.
# Usage: ./scripts/10-postgres-setup.sh   (after terraform apply; az CLI logged into the tenant)
# Re-running resets the sample data.
source "$(dirname "$0")/common.sh"

owner_psql -v ON_ERROR_STOP=1 -f "$ROOT/sql/01-catalog.sql"

APIM_MI="$(tf_out apim_mi_client_id)"
if [[ -n "$APIM_MI" ]]; then
  owner_psql -v apim="$APIM_MI" -f "$ROOT/sql/02-apim-role.sql"
fi

MI_A="$(tf_json tenant_mi_client_ids | jq -r '.a // empty')"
MI_B="$(tf_json tenant_mi_client_ids | jq -r '.b // empty')"
if [[ -n "$MI_A" && -n "$MI_B" ]]; then
  sed -e "s/<TENANT_A_MI_CLIENT_ID>/$MI_A/g" -e "s/<TENANT_B_MI_CLIENT_ID>/$MI_B/g" "$ROOT/sql/03-tenant-rls.sql" \
    | owner_psql -v ON_ERROR_STOP=1 -f -
fi

refresh_data_api
