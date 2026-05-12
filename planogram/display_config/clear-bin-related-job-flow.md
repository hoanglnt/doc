# Job xóa dữ liệu liên quan bin — luồng end-to-end

## Sơ đồ luồng

```mermaid
flowchart TB
  subgraph KAFKA["Kafka"]
    T["Topic: clear_bin_related_job"]
  end

  subgraph BG["fulfillment_wms_accessories_background"]
    M["bin_location messaging → ClearBinRelatedJob"]
    U["Validate → lặp Items"]
    S1["1. clearDesireDisplay"]
    S2["2. clearRequestPush"]
    S3["3. clearRequestReportDisplay"]
    S4["4. clearScheduleLocationConfig"]
    S5["5. clearExpectedStockProductSchedule"]
  end

  subgraph PLAN["Planogram (gRPC)"]
    DD["DesiredDisplay.DeleteMany"]
    DR["DisplayRequest.CancelMany"]
  end

  subgraph ACC["Accessories API (gRPC)"]
    RP["RequestPushLocation.CancelMany"]
  end

  subgraph SCH["fulfillment_wms_schedule"]
    PS["ProductSchedule RPC:\nGetListPagingLocation / DeleteLocation\nGetListPagingExpectedStock / DeleteExpectedStock"]
    IMPL["Handler → usecase product_schedule_config"]
  end

  subgraph QM["fulfillment_wms_queue_manager (liên quan)"]
    Q["Worker tracking schedule/bin,\nDB schedule_config cục bộ,\nproto & Kafka đồng bộ — không gọi trực tiếp từ ClearBinRelatedJob"]
  end

  T --> M --> U
  U --> S1 --> DD
  U --> S2 --> RP
  U --> S3 --> DR
  U --> S4 --> PS
  U --> S5 --> PS
  PS --> IMPL
  QM -.->|"Cùng nghiệp vụ / contract"| SCH
  QM -.->|"Có thể dùng chung topic Kafka"| T
```

## Ba repo đóng vai trò gì

| Repository | Vai trò trong luồng này |
|------------|-------------------------|
| **fulfillment_wms_accessories_background** | **Điều phối**: consume Kafka, chạy `ClearBinRelatedJob`, DB nội bộ + gRPC ra Planogram, Accessories API, Schedule. |
| **fulfillment_wms_schedule** | **Backend schedule**: triển khai gRPC `ProductSchedule` (list + xóa cấu hình vị trí và tồn kỳ vọng). |
| **fulfillment_wms_queue_manager** | **Hệ thống lân cận**: tracking và worker quanh schedule/bin (vd. `schedule_config` cục bộ, messaging location schedule). **Không** nằm trên **chuỗi gọi đồng bộ** của `ClearBinRelatedJob`|
