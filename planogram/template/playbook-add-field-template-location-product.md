# Playbook: add a field on template location product (full stack)

Use when a new column must flow like **`rotate_y`**: gRPC/API → planogram service → history + live DB → reads back out. Pair repo **`planogram_rotate`** with **`gateway_external_rotate`**.

## 0. Pick names and proto number

- **DB / JSON**: `snake_case` (e.g. `block_rotate_y`).
- **Go**: `PascalCase` on structs (e.g. `BlockRotateY`).
- **Proto**: `snake_case` field name; choose the **next unused** field number in each `message` you touch (never recycle numbers).

## 1. Database

Add nullable column on **both** tables (draft + live):

```sql
ALTER TABLE planogram_template_location_product
    ADD COLUMN your_field DOUBLE NULL;  -- or BIGINT/VARCHAR as needed

ALTER TABLE planogram_template_location_product_history
    ADD COLUMN your_field DOUBLE NULL;
```

Commit SQL however your team does migrations (flyway, manual, or `migrations/*.sql`).

## 2. Planogram: proto

File: `proto/planogram/template_factory/template_factory.proto`

- On **`TemplateLocProd`** (request shape): add e.g. `optional double your_field = N;`
- On **`TemplateLocProdRes`** (response shape): same.

Regenerate:

```bash
cd planogram_rotate
make proto-pla FILE_NAME=template_factory
```

## 3. Planogram: persistence layer

### Live

| File | What to do |
|------|------------|
| `application/domains/db/template_factory/template_location_product/entity/template_location_product.go` | Add `gorm:"column:your_field"` on struct; wire **`Export()`** and **`FromSaveRequest()`** |
| `.../template_location_product/models/template_location_product.go` | Add to **`Response`** (json tag) and **`SaveRequest`** |

### History

| File | What to do |
|------|------------|
| `.../template_location_product_history/entity/template_location_product_history.go` | Same pattern as live |
| `.../template_location_product_history/models/template_location_product_history.go` | **`Response`** + **`SaveRequest`** |

## 4. Planogram: mappers

File: `application/domains/template_factory/models/product_template.go`

Every function that copies **`RotateY`** (or peer fields) should also copy **`YourField`**:

- `TempProdHisToTempProdSave`
- `TempProdHisToTempProdRes`
- `TempProdToTempProdHis`
- `TempProdHisToTempProd`
- `TempProdToTempProdHisSave`
- `ToProdHisSaveReq`

File: `application/domains/template_factory/models/template_factory.go`

- Every **`&pb.TemplateLocProdRes{...}`** literal that sets **`RotateY`** → also set **`YourField`** (live items + history items if two blocks exist).

**Why:** approval accept uses `TempProdHisToTempProdSaveMany` → `UpsertMany`; get-by-id uses explicit pb literals.

## 5. Planogram: constants (optional but consistent)

- `application/constant/template_location_product.go` — `FIELD_TEMPLATE_LOCATION_PRODUCT_YOUR_FIELD = "your_field"`
- `application/constant/template_location_product_history.go` — `FIELD_TEMPLATE_LOCATION_PRODUCT_HISTORY_YOUR_FIELD = "your_field"`

If `RequestParams.ToMap()` or repositories filter by column, add mappings there too (mirror how `rotate_y` is used).

## 6. Gateway: proto mirror

File: `gateway_external_rotate/proto/planogram/template_factory/template_factory.proto`

- Same `TemplateLocProd` / `TemplateLocProdRes` fields and **same field numbers** as planogram.

Regenerate:

```bash
cd gateway_external_rotate
make proto-pla FILE_NAME=template_factory
```

Regenerate **Swagger** if your pipeline embeds proto/OpenAPI from these packages (`docs/docs.go`, etc.).

## 7. What usually does *not* need edits

- **`approval_data`** — uses shared mappers; no per-field code if history/live converters are updated.
- **`warehouse_mapping`** `TemplateLocationRes` — bin/location, not product row.
- **`public_display_request` / `display_request`** — separate `TemplateLocProdRes` shapes; only touch if that API must expose the field.

## 8. Inbound path (sanity)

- **`copier.Copy`** from pb → `SaveRequest` requires matching **Go exported names** (`YourField` ↔ proto `your_field` → generated `YourField`). If names diverge, add explicit assignment in the parse function instead of relying on copier.

## 9. Verify

```bash
cd planogram_rotate && go build ./...
cd gateway_external_rotate && go build ./...
```

- Run migration on dev DB; exercise create/update product and get template; accept a template approval and confirm live row has the value.

## Quick checklist

- [ ] DB: live + history column
- [ ] `template_factory.proto` (planogram + gateway) + `make proto-pla`
- [ ] live entity + models
- [ ] history entity + models
- [ ] `product_template.go` (all converters)
- [ ] `template_factory.go` (all `TemplateLocProdRes` literals)
- [ ] constants / filters if applicable
- [ ] `go build ./...` both repos
