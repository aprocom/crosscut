# ROADMAP — plan index

Source of truth is this **index** (set / order / `depends_on` / `feature_id`).
Statuses are reconciled by `/crosscut` at activation, not taken on faith.

**Statuses:** `draft` → `todo` → `validated` → `running` → `review_pending` →
`accepted` → `merging` → `done`; terminal/special: `failed`, `stalled`, `blocked`,
`rejected`, `superseded`. Modifier flags: `plan_review_skipped` (at validated),
`review_deferred` (at done). **Ready** = `todo` + all `depends_on` in `done`.

Plans are grouped **by product** (`cfg_products`). `depends_on` and `feature_id`
never cross a product boundary — a plan may only depend on, or share a `feature_id`
with, plans whose repos resolve to the same product. Status counts and integration
readiness are reported per product.

## Plans by product

<!-- One `## Product:` section per product (from `cfg_products`); one row per active
     plan. done/rejected are derived from each repo's completed/ and rejected/ dirs. -->

## Product: platform (repos: api, web)

| slug | repo | status | depends_on | feature_id |
|------|------|--------|------------|------------|
| 20260101-add-rate-limit-endpoint | api | todo | | rate-limit-ui |
| 20260101-rate-limit-settings-panel | web | todo | 20260101-add-rate-limit-endpoint | rate-limit-ui |

## Product: web-mono (repos: web-mono)

| slug | repo | status | depends_on | feature_id |
|------|------|--------|------------|------------|
