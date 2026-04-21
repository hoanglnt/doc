# Standard Group — Location (bin) type

> Companion to [STANDARD_GROUP_AND_ALTERNATIVE_PRODUCT.md](./STANDARD_GROUP_AND_ALTERNATIVE_PRODUCT.md) (SKU-based standard groups).

This document describes the **location (bin) standard group** feature: master data and sync that apply to **bin codes** across all stores, and how it differs from the existing **SKU-based** standard group flow.

---

## 1. Terminology

| Term | Meaning |
|------|---------|
| **Location (in this feature)** | **Bin code** (e.g. `F0-A0-00-00-00-00`), not warehouse/store. |
| **Standard group type — SKU** | Master defined by product lines (+ optional alternatives). Matches **actual / expected stock** location schedules via product mix. |
| **Standard group type — Location** | Master is still one row in `wms_schedule_standard_group` with `group_type = location`; **bin codes** live in the **link table** (1 group → **many** bins today allowed by schema; product may enforce **one** bin for now in UI/API). |
| **Location schedule config** | Rows under `wms_schedule_config` with `schedule_type = LOCATION_EXPECTED` (`SCHEDULE_CONFIG_TYPE_PRODUCT_LOCATION_EXPECTED` in code). |

**Warehouse:** Not stored on the standard group. Sync matching uses **bin code only** (see §5).

---

## 2. Business rules (summary)

1. One standard group row is either **SKU-type** or **location-type** (`group_type`: `1` = SKU, `2` = location — constants in code).
2. **SKU-type:** Behaves as today: metadata lines, alternative products, `SyncInfo` hash matching to schedules that carry SKU/qty from actual or expected stock configs. **No** rows in `wms_schedule_standard_group_bin` (or ignore them).
3. **Location-type:** **Bin codes** are stored only in **`wms_schedule_standard_group_bin`**; **no** metadata product lines (or reject if present); **no** alternative-product links for that group id.
4. **Global bin uniqueness (among active links):** At any time, a given **bin code** must not appear in more than one **active** row in **`wms_schedule_standard_group_bin`** (`status` = active). **Inactive** rows are retained for history. Duplicate-bin checks on create/import/update should consider **active** rows only. Optional DDL: a partial unique index on **`bin_location`** where **`status`** = active (align with the migration applied in each environment). **Cancel releases the bin:** when **`wms_schedule_standard_group.status_id`** becomes **canceled**, the application deactivates **all active** bin rows for that **`standard_group_id`** and inserts no new ones (same code path as bin replacement: **`ReplaceBinsForStandardGroup`** with no new bin codes; **`SaveRequest.NeedUpdateBinLocations()`** is true when **`StatusId`** is canceled). Flows that cancel the group (e.g. **Cancel** RPC, **RemoveDetails** when the last SKU line is removed and the group auto-cancels) therefore free the bin for another standard group.
5. **Sync separation:** Pushing **location-type** groups to schedules is **not** the same pipeline as SKU `SyncInfo`. There is **no** overwrite conflict: location-expected schedules are **location-only**; SKU sync does not target them as product-hash matches.
6. **Future cardinality:** Schema supports **1 group → many bins**. If the product currently wants **1 group → 1 bin**, enforce that in **application or UI** until requirements change.

---

## 3. Data model

### 3.1 `wms_schedule_standard_group`

| Column | Purpose |
|--------|---------|
| `group_type` | Discriminator: SKU vs location (constants: `1` = SKU, `2` = location / bin). |
| `branch_opening` | `INT NOT NULL DEFAULT 2`: `1` = branch opening, `2` = not branch opening (constants in code). Filterable on list/download (see §4.1). |

The legacy column **`location` was removed** after migration; bins are **only** in the link table.

### 3.2 `wms_schedule_standard_group_bin`

| Column | Purpose |
|--------|---------|
| `standard_group_id` | FK to `wms_schedule_standard_group.id`. |
| `bin_location` | Bin / location code (`VARCHAR(255)`). |
| `status` | `1` = active, `2` = inactive (history kept; list/API reads use **active** rows for `bin_locations` on the record). |
| Audit | `created_by`, `created_at`, `updated_by`, `updated_at` (as per migration). |

Indexes (see migration DDL): e.g. `idx_sgg_id_bin_status` on (`status`, `standard_group_id`, `bin_location`). Product-level **global uniqueness** for “one active bin → one group” may be enforced in application or by additional DDL beyond this doc — align with the migration actually applied in each environment.

**Parent group canceled:** When the standard group row moves to **canceled** status, every **active** link for that **`standard_group_id`** is set **inactive** in one transaction; no new active rows are created for that update. That keeps the “at most one active assignment per bin” rule consistent after cancel.

### 3.3 Application / API

- **`SaveRequest.BinLocations`**: `nil` = do **not** change link rows **unless** the save also **cancels** the group (see below); **non-nil** (including **empty** slice) = **replace** all active bin rows for that group (see `ReplaceBinsForStandardGroup`: deactivate active rows, then insert one row per non-empty bin code).
- **Cancel + bins:** When **`SaveRequest.StatusId`** is **canceled**, **`NeedUpdateBinLocations()`** is true so **`schedule_standard_group` `Update`** runs **`ReplaceBinsForStandardGroup`** with **`BinLocations` nil** → deactivate all active rows, insert none. SKU-type groups typically have no bin rows; the call is a no-op for them.
- **Reads** (`GetListPaging`, `GetDetail`, etc.): **`repeated bin_locations`** on **`ScheduleStandardGroup`** is populated from the link table (active rows; list query uses `GROUP_CONCAT` as `bin_locations_csv`).

**No** new column on `wms_schedule_config` linking back to `standard_group_id`; relationship for sync is still **derived** by matching schedule bin to a row in `wms_schedule_standard_group_bin`.

### 3.4 Migrations

Single script (run once per environment; MySQL 8+ for generated column):

- [`.doc/migrations/20260406120000_wms_schedule_standard_group_group_type_and_bins.sql`](../migrations/20260406120000_wms_schedule_standard_group_group_type_and_bins.sql) — adds **`group_type`** and **`branch_opening`** on `wms_schedule_standard_group`; creates **`wms_schedule_standard_group_bin`** with **`bin_location`** + **`status`**. (If your environment still has an older story with `location` backfill / drop, reconcile from git history — the checked-in script is the current single-file reference.)

If you already applied an older split migration set, do not re-run this whole script; align manually or use git history for the previous files.

---

## 4. API surface (REST-style paths as in gateway comments)

### 4.1 Filters on list (and download)

- **`group_type`** — **`GetListPaging`** / **`DownloadRequest`**: equality filter (`0` = no filter; otherwise match `wms_schedule_standard_group.group_type`).
- **`branch_opening`** — same requests: equality (`0` = no filter; `1` = branch opening, `2` = not branch opening — see DB comment / constants). Also returned on each **`ScheduleStandardGroup`** as **`branch_opening`** (proto JSON e.g. **`branchOpening`**).
- **Bin prefix filter** — single string **`bin_location_prefix`** on **`GetListPaging`** / **`DownloadRequest`** (distinct from **`repeated bin_locations`** on each record, which is the full bin list for that group). Semantics: standard groups match if **any** **active** row in **`wms_schedule_standard_group_bin`** has **`bin_location`** matching **`prefix%`** via SQL **`LIKE`** (metacharacters in the prefix are escaped so `\`, `%`, `_` are literal). Empty string = no filter. Typically combined with **`group_type = location`** in the UI.
- **Export payload** — **`DownloadMessage.filter`** includes the same filter fields (e.g. **`bin_location_prefix`**, **`branch_opening`**, **`group_type`**, …) so the export worker can replay list criteria; consumers must use **`bin_location_prefix`** (not a comma-separated bin list).

### 4.2 Create location standard group (`CreateLocationStandardGroup`)

**gRPC:** `CreateLocationStandardGroup` → `CreateLocationStandardGroupResponse` with **`record`** (`ScheduleStandardGroup`).

**Proto comment (HTTP):** `POST /locations/create` — add **`google.api.http`** on your gateway if you expose REST.

**Flow:** Handler builds **`UcCreateLocationStandardGroupRequest`** via **`ParseFromPb`** (same pattern as **GetListPaging** + **`RequestParams`**); usecase validates, checks bin uniqueness, then **`schedule_standard_group` service `Create`** with a **`SaveRequest`** (location-type, draft status, generated **`group_code`**, one active bin row via **`ReplaceBinsForStandardGroup`**).

| Request field (proto) | Behaviour |
|------------------------|-----------|
| **`bin_location`** | Required (struct + proto validate). Trimmed. Must split into exactly **`LOCATION_CODE_LENGTH`** (6) segments separated by **`-`** (e.g. `F0-A0-00-00-00-00`). |
| **`duration`** | If **`0`**, default **`DEFAULT_DURATION`** (360 seconds). Otherwise must be **`> 0`** and **`≤ MAX_DURATION`** (10800). |
| **`branch_opening`** | If **`0`**, default **`1`** (yes). Allowed: **`1`** = yes, **`2`** = no (see **`SCHEDULE_STANDARD_GROUP_BRANCH_OPENING_*`**). |
| **`is_active`** | If **`0`**, default **`CONFIG_ACTIVE`** (1). Allowed: **`1`** = active, **`2`** = inactive (**`CONFIG_ACTIVE` / `CONFIG_INACTIVE`**). |

**Persistence:** New row gets **`group_type`** = location, **`status_id`** = draft, **`group_name`** = **`bin_location`**, **`branch_opening`** and **`is_active`** as resolved above; link table gets one **active** **`bin_location`** row.

**Duplicate bin:** Before create, service lists link rows via **`schedule_standard_group_bin`** **`GetList`** with **`bin_location`** + **`status`** = active ( **`RequestParams.ToMap()`** ). If any row exists → **`AlreadyExists`** (no second active assignment for the same bin).

### 4.3 Same paths as today (by id; shared lifecycle)

These stay on the **existing** route shape (no `/locations` prefix). Handlers branch on `group_type` where validation differs:

- Detail, edit, toggle, cancel, picture flows — **`:id*`** style routes
- **`/approve`**, **`/reject`**, **`/detail`**, **`/re-open`**
- **`Update` (`UpdateRequest`)** — optional **`branch_opening`** (proto field **`6`**): **`0`** = do not change; **`1`** / **`2`** = set branch opening **only for location-type** groups (`group_type = 2`). For SKU-type groups, sending **`1`** or **`2`** returns **`InvalidArgument`**.

### 4.4 GetDetail (P3 — `record` + UI contract)

**gRPC:** `GetDetail` → `GetDetailResponse` with `record` (`ScheduleStandardGroup`) and `details` (paged product lines, same shape as today).

**JSON / UI (align with proto JSON names from your gateway, often camelCase):**

| Field (concept) | Meaning |
|-----------------|--------|
| **`record.groupType`** | `1` = SKU-type, `2` = location-type (see constants in code). |
| **`record.branchOpening`** | `1` / `2` as stored on `wms_schedule_standard_group.branch_opening`. |
| **`record.binLocations`** | Repeated/list of bin codes from **`wms_schedule_standard_group_bin`** (**active** rows only), same source as list `GROUP_CONCAT` order. |
| **`record.totalSku`** / **`record.totalQuantity`** | Same semantics as **GetListPaging**: counts from **`wms_schedule_metadata`** for `STANDARD_GROUP`. |
| **`details`** | Paged SKU lines for the group; still populated from schedule metadata as today. |

**SKU-type groups (`groupType === 1`):** Behaviour unchanged for callers that only used SKU flows: **`binLocations`** is present but typically **empty**; UI should not rely on bins. **`totalSku` / `totalQuantity`** reflect product lines.

**Location-type groups (`groupType === 2`):** **`binLocations`** is **authoritative** for where the group applies. **`details`** may be **empty** (no metadata product lines); **`totalSku` / `totalQuantity`** are often **0** — treat as normal unless product specifies otherwise.

**How to verify:** Call **GetDetail** with `id` (+ optional `page` / `size` for `details`). Compare **`record`** fields with **GetListPaging** for the same id. Optional: [`scripts/smoke_schedule_standard_group_list_paging.sh`](../../scripts/smoke_schedule_standard_group_list_paging.sh) with `SMOKE_RPC=get_detail`.

### 4.5 Under `/locations` prefix

Used for flows that differ materially (templates, bulk file, sync entry points) for **location-type** standard groups:

| Relative segment | gRPC method (`ScheduleStandardGroupService`) | Purpose |
|------------------|---------------------------------------------|---------|
| `/locations/create` | **`CreateLocationStandardGroup`** | **Create** one **location-type** standard group with a single bin |
| `/locations/import` | **`LocationImportExcel`** | Bulk import location-type groups from Excel (P7) |
| `/locations/validate` | **`LocationValidateExcel`** | Validate location Excel; returns **`ValidateLocationExcelResponse`** (P7) |
| `/locations/download` | **`LocationDownload`** | Export — stub until P8 |
| `/locations/download-template` | **`LocationDownloadTemplate`** | Download location import template (P7) |
| `/locations/sync` | **`LocationSync`** | Sync approved location-type groups — stub until P9 |
| `/locations/apply-all` | **`LocationApplyAll`** | Apply-all for location-type — stub until P10 |

HTTP verb + path hints live as **comments** on each `rpc` in [`schedule_standard_group.proto`](../../proto/schedule/schedule_standard_group/schedule_standard_group.proto) (same convention as other planogram schedule-standard-group routes; this repo does not use `google.api.http` annotations). If your **API gateway** lives in another repository, register these paths to the **full gRPC method names** above (not the SKU-only `ImportExcel` / `Download` / `Sync` / `ApplyAll` methods).

### 4.6 Location Excel template and validation (P7)

**Unlike the SKU standard group import** (one row = one metadata line), the **location** template allows **multiple rows per group name**: shared fields (**duration**, **branch opening**, **active**) must be **consistent** for all rows with the same **group name**; each row with a **standard name** adds one entry to the group’s **`standard_image`** list (same grouping idea as location expected-stock import in `product_schedule_config` / `ValidateExcelLocation`).

**Columns** (header labels in the file):

| Column | Required | Notes |
|--------|----------|--------|
| **Group name** | Yes | Stored as **`group_name`**. **Current import:** the value is also the **single bin code** for the group (same segment rules as **`CreateLocationStandardGroup`** / `validBinLocation`); **`BinLocations`** on save is **`[group name]`**. A separate **Bin location** column is **not** in the template until product adds multi-bin-per-group Excel support. |
| **Duration** | Optional on continuation rows | One distinct non-empty value per group name, in range **`(0, MAX_DURATION]`**; if all rows for that name omit it, **default duration** applies. |
| **Branch opening** | Optional on continuation rows | **Yes** / **No** or **1** / **2**; one distinct value per group name; default **Yes** (branch opening) if omitted everywhere. |
| **Active** | Optional on continuation rows | **Yes** / **No** or **1** / **2** (active / inactive); one distinct value per group name; default **active** if omitted everywhere. |
| **Standard name** | Optional | If set, defines **`ImageName`** for one standard image; **duplicate standard name for the same group name** in the file is invalid. |
| **Description of standard** | Optional | **`ImageDescription`**; requires **standard name** on the same row. |

**Validate RPC:** **`LocationValidateExcel`** returns **`ValidateLocationExcelResponse`** with **`repeated ValidateLocationExcelErrorResponse err_msgs`**, each carrying **`group_name`**, **`duration`**, **`branch_opening`**, **`active`**, **`standard_name`**, **`description_of_standard`**, and **`error_message`** (not the SKU **`ValidateExcelResponse`** shape).

**Import:** one **`wms_schedule_standard_group`** **per distinct group name** in the file. **Create / update id** is resolved by **`GetList`** with **`group_name`** (exact) and **`group_type`** = location (0 rows → create draft; 1 row → update that id; **>1** row with same name → validation error). **Bin link checks** (ambiguous active links, non-location group, bin tied to another group than the target) still use **`wms_schedule_standard_group_bin`** in batch. **Update:** existing location group id from name; **`ReplaceBinsForStandardGroup`** applies **`[group name]`** as the bin list for this phase.

**Template registry:** the builder key **`template_import_excel_schedule_standard_group_location`** must exist in your template-builder configuration (same pattern as the SKU standard group template key).

---

## 5. Sync behaviour

### 5.1 Who receives updates

- **Only** schedules originating from **`LOCATION_EXPECTED`** config (`SCHEDULE_CONFIG_TYPE_PRODUCT_LOCATION_EXPECTED`).
- Match rule: **every** such config whose **bin code is in the group’s bin list** (`wms_schedule_standard_group_bin` for that `standard_group_id`) is eligible.
- **Warehouse is not** part of the match; standard group does not store warehouse.

### 5.2 What is synced

Same as current SKU sync **payload to the location schedule row**: standard image, duration, display description (whatever `updateStandardImage` / existing save path already writes). **No** new link column on `wms_schedule_config`.

### 5.3 Cardinality

- **DB:** Many bins per group allowed; **each bin** should appear in **at most one** group (enforce per product / DDL as deployed).
- One **LOCATION_EXPECTED** schedule row ↔ match if its bin is in **some** location-type group’s bin set (implicit; no stored FK on `wms_schedule_config`).

---

## 6. Related code areas (implementation hints)

| Area | Notes |
|------|--------|
| `application/constant/schedule_config.go` | `SCHEDULE_CONFIG_TYPE_PRODUCT_LOCATION_EXPECTED` |
| `application/domains/db/schedule_standard_group_bin/` | Link table repository: **`GetList` / `GetListPaging` / `Count`** + **`filter(queries map)`**; **`ReplaceBinsForStandardGroup`**, **`ListBinLocationsByStandardGroupId`**; **`models.RequestParams.ToMap()`**. |
| `application/domains/schedule_standard_group/usecase/create_location.go` | **`CreateLocationStandardGroup`**: validation, duplicate-bin check via **`ListStandardGroupBins`**, **`service.Create`**. |
| `schedule_standard_group` gRPC handler | **`CreateLocationStandardGroup`**: **`UcCreateLocationStandardGroupRequest.ParseFromPb`**. |
| `application/domains/schedule_standard_group/usecase/sync_info.go` | SKU `SyncInfo` / `FindScheduleIdMatching` — **do not** force location groups through product hash; add a **separate** branch or use case for location-type |
| `planogram_alternative_product` / Alternative Product gRPC | Reject or no-op for location-type `standard_schedule_id` |
| Product schedule / location schedule config | Query `LOCATION_EXPECTED` configs by bin for sync target resolution |

---

## 7. Explicitly out of scope (unless product asks)

- Extra indexes beyond those in the bin-table migration (add explicit **global uniqueness** on active **`bin_location`** if not already in your environment’s DDL).
- `standard_group_id` (or similar) on `wms_schedule_config`.
- Warehouse-scoped matching on the standard group row.

---

## 8. Related documents

- [STANDARD_GROUP_AND_ALTERNATIVE_PRODUCT.md](./STANDARD_GROUP_AND_ALTERNATIVE_PRODUCT.md)
- [STANDARD_GROUP_AND_ALTERNATIVE_PRODUCT.vi.md](./STANDARD_GROUP_AND_ALTERNATIVE_PRODUCT.vi.md)

---

## 9. Phased implementation plan

Each phase is **independently reviewable**. Stop after any phase for QA or PR. Do **not** skip verification of earlier phases before starting dependent work.

| Phase | Scope | Deliverable | How to verify |
|-------|--------|-------------|----------------|
| **P0** | **Constants + DB** | `group_type` + **`branch_opening`** on `wms_schedule_standard_group`; link table (see §3.4); Go entity/models/constants. | Migrations applied; list/detail load **`bin_locations`** on the record; create defaults **`group_type`** = SKU, **`branch_opening`** = not branch opening unless set. |
| **P1** | **Proto + list** | Extend **`ScheduleStandardGroup`** and **`GetListPagingRequest`** with **`group_type`**, **`branch_opening`** (+ **`repeated bin_locations`** on record); regenerate stubs; **GetListPaging** filters by **`group_type`** / **`branch_opening`**; repository/query support. | gRPC list returns **`group_type`**, **`branch_opening`**, **`bin_locations`**; filters narrow rows as expected. |
| **P2** | **List filter by bin prefix** | **`bin_location_prefix`** on **`GetListPagingRequest`** and **`DownloadRequest`**; `RequestParams` + **`ToMap()`** key **`bin_location_prefix`**; repository **`EXISTS`** on **`wms_schedule_standard_group_bin`**, **active** rows only, **`bin_location LIKE`** prefix match (escaped). **`DownloadMessage.filter.bin_location_prefix`** for export jobs. | UI search by bin prefix; list + export parity; optional **`group_type = 2`**. |
| **P3** | **Read paths** | **GetDetail** returns `group_type` + bin list; UI contract documented. | Detail for SKU groups unchanged semantically; location groups show bins, empty/zero SKU totals as agreed. |
| **P4** | **Write rules — SKU unchanged** | Validation on create/update: **SKU-type** ignores / clears bin links; **location-type** requires at least one bin (if product says 1 only, enforce count = 1), no metadata lines. **`CreateLocationStandardGroup`** implements **single-bin** location create (see §4.2). | Integration tests: cannot save invalid combinations; create rejects duplicate active bin. |
| **P5** | **Alternative product guard** | For `standard_schedule_id` referencing a **location-type** group: return error or empty from alternative-product APIs. | Alt APIs do not create rows for location groups. |
| **P6** | **Proto + handler stubs — `/locations` RPCs** | New or duplicated gRPC methods with `google.api.http` comments under `/locations/...` for import, validate, download, download-template, sync, apply-all; handlers delegate or return `Unimplemented` until P7–P9. | Gateway map shows new routes. |
| **P7** | **Location import / validate / template** | Implement Excel flow for location-type only; wire to `/locations/import`, `/locations/validate`, `/locations/download-template`. | Upload template → validate → DB rows for location-type only; SKU import unchanged. |
| **P8** | **Location export** | `/locations/download` for location-type list/export. | File contents match spec; SKU export still uses old download. |
| **P9** | **Location sync** | New sync path: load **approved + active** location-type groups, resolve all `LOCATION_EXPECTED` configs whose bin is **in the group’s bin list**, call same **`updateStandardImage`** (or shared helper) as today. **Do not** route through `FindScheduleIdMatching` product hash. | Updates all matching schedules; SKU sync untouched. |
| **P10** | **Location apply-all** | `/locations/apply-all` mirrors SKU apply-all but uses location sync path only. | Same as P9 with multiple ids. |
| **P11** | **Lifecycle + Kafka** | Confirm **approve / toggle active** for location-type publishes same downstream events as SKU groups **if** product requires sync on approve; otherwise document difference. | Staging: approve location group triggers expected jobs. |
| **P12** | **Hardening** | Logging, metrics, edge cases (unknown bin string, deleted configs), regression tests on existing SKU standard group flows. | Full regression pass; GitNexus `impact` on `SyncInfo` / new sync entry points documented for reviewers. |

### Dependency notes

- **P9–P10** depend on **P0–P4** and querying **`LOCATION_EXPECTED`** rows by bin in this codebase.
- **P6** can start early as **contract-only** if frontend needs route stability before P7–P10.

### GitNexus / safety

- Before editing **`SyncInfo`** or shared **`updateStandardImage`**, run **`gitnexus_impact`** on the symbol(s) you change.
- Prefer **adding** a dedicated function for location sync over growing `FindScheduleIdMatching` with fake products.

---

*After large code changes, refresh GitNexus index if used: `npx gitnexus analyze`.*
