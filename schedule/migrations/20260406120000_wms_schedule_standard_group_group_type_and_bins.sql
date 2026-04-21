-- Standard group: group_type + location (staging) + link table with soft status, backfill, drop location.
-- Merged from former 20260406120000 / 20260406140000 / 20260406150000 — run once per environment.
-- Requires MySQL 8+ (generated STORED column).

-- 1) Discriminator and legacy single-bin column (backfill source)
ALTER TABLE `wms_schedule_standard_group`
  ADD COLUMN `group_type` INT NOT NULL DEFAULT 1 COMMENT '1=SKU, 2=location (bin)' AFTER `standard_image`,
  ADD COLUMN `branch_opening` INT NOT NULL DEFAULT 2 COMMENT '1=branch opening, 2=not branch opening' AFTER `group_type`;

-- 2) Link table: soft status (1 active, 2 inactive); global uniqueness for active bins only
CREATE TABLE IF NOT EXISTS `wms_schedule_standard_group_bin` (
  `id` BIGINT NOT NULL AUTO_INCREMENT,
  `standard_group_id` BIGINT NOT NULL COMMENT 'wms_schedule_standard_group.id',
  `bin_location` VARCHAR(255) NOT NULL COMMENT 'Bin / location code',
  `status` TINYINT NOT NULL DEFAULT 1 COMMENT '1 active 2 inactive',
  `created_by` BIGINT DEFAULT NULL,
  `created_at` TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_by` BIGINT DEFAULT NULL,
  `updated_at` TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_sgg_id_bin_status` (`status`,`standard_group_id`, `bin_location`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Bins linked to a schedule standard group; inactive rows kept for history';