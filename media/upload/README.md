# Upload documentation

- **[Presigned upload flow](presigned-upload-flow.md)** — `GenerateUploadURLs` → direct PUT to R2 → `CompleteUpload`: sequence, payloads, and integration notes.
- **[Video transcode (`CompleteUpload`) plan](video-transcode-complete-upload-plan.md)** — `is_transcode`, Kafka enqueue, worker HLS, new `files` row for `master.m3u8`.
