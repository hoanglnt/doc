# Workflow example — Location standard group feature

Use this document as a **template** for how we took a spec from `.doc` through design, implementation, verification, and documentation. Adapt sections per feature.

---

## 1. Source of truth

| Artifact | Role |
|----------|------|
| [STANDARD_GROUP_LOCATION_SPEC.md](./STANDARD_GROUP_LOCATION_SPEC.md) | Product + data model + API + phased plan (P0–P12) |
| [P9_LOCATION_DECLARATION_SYNC.md](./P9_LOCATION_DECLARATION_SYNC.md) | Deep dive: how location-expected declarations are identified and how `LocationSync` resolves targets |
| [STANDARD_GROUP_AND_ALTERNATIVE_PRODUCT.md](./STANDARD_GROUP_AND_ALTERNATIVE_PRODUCT.md) | SKU-type standard groups (companion) |
| [Migrations](../migrations/) | DDL reference (e.g. `group_type`, `branch_opening`, `wms_schedule_standard_group_bin`) |

**Rule:** Implement against the spec; update the spec when behavior or contracts change.

---

## 2. Workflow steps (repeatable)

### 2.1 Read and slice the spec

1. Read the main spec end-to-end; note **phases**, **dependencies**, and **out of scope**.
2. List **invariants** (e.g. “location sync must not use SKU hash matching”).
3. Identify **touch points**: domains, gRPC, Kafka, external services, DB columns.

### 2.2 Safety / impact (GitNexus, if indexed)

Before editing shared symbols (e.g. `SyncInfo`, `updateStandardImage`):

- Run **impact** on the symbol you will change; note **d=1** callers and risk.
- After a meaningful change set, run **detect_changes** before commit (per project rules).

### 2.3 Data model first

- Confirm migrations vs entity: `group_type`, `branch_opening`, bin link table, optional `extend_info`.
- Keep **repository** dumb where possible: plain columns as strings on entity; **typed JSON** in **db `models`** (`ExtendInfo`, merge helpers).

### 2.4 API and reads

- Proto + handler comments for gateway paths (`/locations/...` vs shared `:id` routes).
- List/detail: filters (`group_type`, `branch_opening`, `bin_location_prefix`); `bin_locations` from **active** bin rows only.

### 2.5 Write rules and invariants

Examples from this feature:

- **Cancel** standard group → **deactivate all active** `wms_schedule_standard_group_bin` rows for that group (reuse `ReplaceBinsForStandardGroup` with no new codes); document in spec so “one active bin ↔ one group” stays clear.
- **Location sync** separate from SKU: dedicated use case path + queue flag `is_location_sync`.

### 2.6 Cross-cutting behavior

- **Kafka / queue_manager:** same topic as SKU when acceptable; branch on flag to call `LocationSync` vs `Sync`; regenerate protos in consumer repo.
- **Display-only counters:** store in `extend_info`, update on successful location sync, read in `Export()` — avoid expensive subqueries on list.

### 2.7 Downstream jobs (reuse, don’t duplicate)

When the same gRPC / side-effect appears in two flows (e.g. standard-evaluate **mapping** after location updates):

1. Extract to a **service** method with a clear contract (e.g. `map[locationScheduleId]standardGroupId`).
2. Call from **parent** use cases (`updateStandardImage`, `processLocationScheduleFromConfig`).
3. Log errors consistently; decide **fail vs warn** per product risk.

### 2.8 Config-driven creation (optional)

When product config jobs create declarations:

- Prefer **approved location standard group** (active, branch opening yes) over **code default** when bin matches.
- Use **service `GetList`** with filters (e.g. `FilterBinCodes` for exact bins) instead of ad-hoc repo access when it improves maintainability.
- Track **which bins** auto-approve this run; after `CreateMany`, run mapping sync then approve if required.

### 2.9 Documentation pass

- Update **STANDARD_GROUP_LOCATION_SPEC.md** when business rules change (e.g. cancel + bins).
- Add or refresh a **focused** doc (e.g. P9) for debugging and onboarding.

### 2.10 Verification checklist

- [ ] `go build ./...`
- [ ] List/detail filters and `bin_locations` for location vs SKU groups
- [ ] Approve / toggle → correct Kafka branch → `LocationSync` / `Sync`
- [ ] Cancel → bin rows inactive; create with same bin succeeds after cancel
- [ ] `extend_info` / `schedule_applied_count` after location sync
- [ ] Standard evaluate mapping after sync **and** after config-driven create (if applicable)

---

## 3. File map (this feature — high level)

| Area | Paths (examples) |
|------|-------------------|
| Location sync | `application/domains/schedule_standard_group/usecase/sync_info.go` |
| Standard group DB | `application/domains/db/schedule_standard_group/` (models, entity, repo, service) |
| Bin link | `application/domains/db/schedule_standard_group_bin/` |
| Location schedule config job | `application/domains/location_schedule_config/usecase/usecase.go`, `default_schedule.go`, `process_location_schedule_expected.go` |
| Mapping sync (shared) | `application/domains/db/location_schedule_config/service/service.go` (`SyncStandardEvaluateMappingByStandardGroups`) |
| Constants | `application/constant/schedule_standard_group.go`, `location_schedule_config.go`, … |
| Specs | This folder + `../migrations/` |

---

## 4. What “done” looked like for this example

- Spec phases through **P9/P10/P11** behavior covered in code paths we touched; **P12** = ongoing hardening (tests, metrics, edge cases).
- **Single workflow doc** (this file) for the next engineer to clone the process on another feature.

---

*After large refactors, refresh GitNexus if your team uses it: `npx gitnexus analyze`.*
