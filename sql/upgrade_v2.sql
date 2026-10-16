-- mdp_garages schema v1 -> v2 (manual alternative; the resource also does this on start).
-- Idempotent on MariaDB 10.3+ (ADD COLUMN IF NOT EXISTS). On MySQL 8, skip the ALTER if the column exists.
ALTER TABLE `mdp_vehicles`
  ADD COLUMN IF NOT EXISTS `vtype` VARCHAR(16) NOT NULL DEFAULT 'automobile'
  COMMENT 'automobile|bike|boat|heli|plane (CreateVehicleServerSetter type)' AFTER `model`;
INSERT IGNORE INTO `mdp_schema_version` (`version`) VALUES (2);
