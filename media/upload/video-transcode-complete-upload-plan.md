# Video transcode from `CompleteUpload` — implementation plan

This document captures the agreed design for triggering MP4/MOV → HLS (stream) transcoding via the existing **`CompleteUpload`** flow, worker processing, and **new `files` row** for the manifest (original upload row untouched).

---

## Repos

| Repo | Role |
|------|------|
| `fulfillment_media` | gRPC/file domain: extend `CompleteUpload`, Kafka publish to video transcode topic |
| `fulfillment_media_background` | Kafka consumer, FFmpeg HLS pipeline, **`CreateMany`** for `master.m3u8` metadata row |
| `fulfillment_gateway_external` | Proto mirror under `proto/media/file/` where gateway codegen expects it |

---

## Frozen decisions

1. **No separate RPC** named e.g. `TranscodeVideoToStream`. Clients pass **`is_transcode`** on **`CompleteUploadRequest`**.
2. **Videos eligible:** object keys ending in **`.mp4`** / **`.mov`** (canonicalize with lowercase extension checks).
3. **When:** `CompleteUpload` runs as today (metadata/size update, validation). Additionally, if **`is_transcode`** and at least one video key → publish one Kafka message per video key (or agreed batch strategy) to the **video transcode** producer topic.
4. **Image background path** unchanged: image keys continue to enqueue **`CompleteUploadMessage`** → **ImageProcessing** topic when resize/RMBG flags apply (existing behavior).
5. **Post-transcode persistence:** **`CreateMany`** inserts a **new** row in **`files`** for the **`master.m3u8`** object key only. **Do not update** the original video **`files`** row.
6. **Kafka payload** must include **`source_object_key`** so the worker can **`GetList`** / resolve the parent file row and copy **`Project*`**, **`Folder*`**, **`Status`** into the derivative row (same idea as thumbnail rows in image processing).

---

## Phase 1 — Media service: enqueue

1. **`proto/media/file/file.proto`** (and **mirror** in `fulfillment_gateway_external`):
   - Add `bool is_transcode` to **`CompleteUploadRequest`**.
2. **`fulfillment_media` config:**
   - Add **`Service.Kafka.Producers.VideoTranscode`** string (YAML per environment).
   - Extend `config` structs to load it (pattern matches `ImageProcessing` producer).
3. **Models / handler:**
   - Add **`IsTranscode`** on `CompleteUploadRequest` model + **`ParseFromCompleteUploadPb`**.
4. **`CompleteUpload` usecase** (`application/domains/file/usecase/usecase.go`):
   - After successful updates (existing loop unchanged):
   - If **`params.IsTranscode`**: iterate **`params.ObjectKeys`**, detect video via helper e.g. **`IsVideo`**.
   - For each video key: marshal **`VideoJob`** JSON compatible with worker (must include **`source_object_key`**; **`video_id`** strategy: reuse stable id e.g. hash/namespaced-from-key or UUID — confirm with team).
   - **`WriteByKey`** to **`config.Service.Kafka.Producers.VideoTranscode`** topic.
   - Guard: empty topic → clear error (`FailedPrecondition` / `Internal` per existing Kafka patterns).
5. Regenerate protobuf Go code where applicable.

---

## Phase 2 — Background: job schema + consume

1. Extend **`VideoJob`** in **`video_transcode.go`** with **`SourceObjectKey`** (JSON `source_object_key`), keep **`video_id`** / **`source_url`** as needed:
   - **Recommendation:** derive HTTP download URL in worker from **`source_object_key`** + configured CDN/R2 host (avoid stale presigned URLs in message). If `source_url` present, optionally allow override for phased rollout.
2. **`ProcessVideoTranscodeMessage`:** unmarshal → validate **`source_object_key`** → populate internal job → existing **`runVideoTranscodePipeline`** (download → ffmpeg → upload under `R2OutputPrefix/video_id/`).
3. No change required to topic routing beyond existing **`ProcessMessage`** switch on **`VideoTranscode.Topic.Process`**.

---

## Phase 3 — Background: persist HLS manifest as new file row

1. After successful upload of HLS output, derive **`manifestKey`** = `{R2OutputPrefix}/{video_id}/master.m3u8` (align with pipeline).
2. **Parent lookup:** **`u.service.GetList`** (or equivalent) with **`FileNames = source_object_key`** to load the original **`files`** row.
3. Build **one **`SaveRequest`**:**
   - **`FileName`** = `manifestKey`
   - **`ProjectId/Code`**, **`FolderId/Code`**, **`Status`** copied from parent
   - **`Size`**: KB from manifest stat if trivial; otherwise `0`/minimal until a follow-up (document choice).
4. **`service.CreateMany(ctx, USER_API, []*SaveRequest{…})`** — same stack as thumbnail derivatives.
5. **Idempotency:** if a row already exists for `manifestKey`, **skip** or **no-op** (prefer skip + log).

---

## Phase 4 — Later / optional

- **Status persistence** (enqueue / processing / ready / failed) — DB/redis choice TBD.
- **Status polling API** in `fulfillment_media` + gateway protos.
- **Metrics / DLQ** for failed FFmpeg or upload.
- Duplicate **`CompleteUpload` + `is_transcode`** for same object key: policy (reject vs allow idempotent enqueue).

---

## Verification checklist

- [ ] Proto parity: `fulfillment_media` ↔ `fulfillment_gateway_external` for `CompleteUploadRequest`.
- [ ] Worker consumes same producer topic configured in media.
- [ ] One new **`files`** row per successful transcode pointing at **`master.m3u8`** key; original video row unchanged.
- [ ] Gateway/file API returns playable URL via existing URL template behavior for the new **`file_name`**.

---

## Related docs

- [Presigned upload flow](presigned-upload-flow.md) — upload → `CompleteUpload` context.
