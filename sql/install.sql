-- mdp_garages install schema (MySQL 5.7+/MariaDB 10.3+, via oxmysql)
-- All tables are prefixed `mdp_` to avoid clashing with ESX `owned_vehicles`
-- and QBCore/Qbox `player_vehicles`. Framework tables are never modified.
-- `owner` / `holder` = ESX identifier or QB/Qbox citizenid (Bridge.GetIdentifier).
-- mdp_vehicles.state: 0=out, 1=garaged, 2=parked_world, 3=impounded, 4=retired, 5=removed (soft delete) (Constants.VehicleState)
-- Plates: VARCHAR(12) for headroom; code enforces 1-8 chars [A-Z0-9 ] (Utils.IsValidPlate).
-- Not applied automatically: run this file once (HeidiSQL / mysql CLI). Safe to re-run.

CREATE TABLE IF NOT EXISTS `mdp_vehicles` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `plate`       VARCHAR(12)  NOT NULL,
  `owner`       VARCHAR(64)  NOT NULL,
  `model`       VARCHAR(64)  NOT NULL,
  `vtype`       VARCHAR(16)  NOT NULL DEFAULT 'automobile' COMMENT 'automobile|bike|boat|heli|plane (CreateVehicleServerSetter type)',
  `props`       LONGTEXT     NULL COMMENT 'JSON vehicle properties',
  `coords`      LONGTEXT     NULL COMMENT 'JSON {x,y,z} last world position',
  `heading`     FLOAT        NOT NULL DEFAULT 0,
  `state`       TINYINT UNSIGNED NOT NULL DEFAULT 1,
  `fuel`        FLOAT        NOT NULL DEFAULT 100,
  `engine`      FLOAT        NOT NULL DEFAULT 1000,
  `body`        FLOAT        NOT NULL DEFAULT 1000,
  `mileage`     DOUBLE       NOT NULL DEFAULT 0 COMMENT 'km',
  `source`      VARCHAR(16)  NOT NULL DEFAULT 'mdp' COMMENT 'framework = imported by sync/migrate (eligible for SyncRemovals); mdp = AddVehicle/own',
  `garage_id`   VARCHAR(64)  NULL COMMENT 'public|private|impound:<id>',
  `parked_at`   TIMESTAMP    NULL DEFAULT NULL COMMENT 'when state became parked_world (inactivity retire, phase 7)',
  `managed_at`  DATETIME     NULL DEFAULT NULL COMMENT 'first time mdp spawned/stored/parked/adopted it (v5; NULL = never managed)',
  `first_seen_at` DATETIME   NULL DEFAULT NULL COMMENT 'v6: server time mdp detected this framework row in an incremental sync (NULL = initial import / not adoptable)',
  `fw_date_at`  DATETIME     NULL DEFAULT NULL COMMENT 'v6: framework purchase/creation date at detection, if the framework table has one',
  `created_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_mdp_vehicles_plate` (`plate`),
  KEY `idx_mdp_vehicles_owner` (`owner`),
  KEY `idx_mdp_vehicles_state` (`state`),
  KEY `idx_mdp_vehicles_garage` (`garage_id`),
  KEY `idx_mdp_vehicles_state_parked` (`state`, `parked_at`),
  KEY `idx_mdp_vehicles_owner_garage` (`owner`, `garage_id`, `state`),
  KEY `idx_mdp_vehicles_owner_source` (`owner`, `source`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `mdp_vehicle_keys` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `plate`       VARCHAR(12)  NOT NULL,
  `holder`      VARCHAR(64)  NOT NULL,
  `granted_by`  VARCHAR(64)  NOT NULL,
  `created_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_mdp_keys_plate_holder` (`plate`, `holder`),
  KEY `idx_mdp_keys_holder` (`holder`),
  CONSTRAINT `fk_mdp_keys_plate` FOREIGN KEY (`plate`) REFERENCES `mdp_vehicles` (`plate`)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `mdp_private_garages` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `owner`       VARCHAR(64)  NOT NULL,
  `config_id`   VARCHAR(32)  NOT NULL COMMENT 'property/garage key from server config (one purchase per owner+config)',
  `label`       VARCHAR(64)  NOT NULL,
  `interior`    VARCHAR(64)  NOT NULL COMMENT 'interior key from server config',
  `entrance`    LONGTEXT     NOT NULL COMMENT 'JSON {x,y,z,w}',
  `slots`       TINYINT UNSIGNED NOT NULL DEFAULT 2,
  `price`       INT UNSIGNED NOT NULL DEFAULT 0,
  `created_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_mdp_pgarages_owner` (`owner`),
  UNIQUE KEY `uq_mdp_pgarages_owner_config` (`owner`, `config_id`),
  UNIQUE KEY `uq_mdp_pgarages_owner_label` (`owner`, `label`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `mdp_impound` (
  `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `plate`         VARCHAR(12)  NOT NULL,
  `reason`        VARCHAR(255) NULL,
  `officer`       VARCHAR(64)  NULL COMMENT 'identifier of officer / tow driver',
  `fee`           INT UNSIGNED NOT NULL DEFAULT 0,
  `released`      TINYINT(1)   NOT NULL DEFAULT 0,
  `impounded_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `release_after` TIMESTAMP    NULL DEFAULT NULL,
  `location`      VARCHAR(64)  NULL COMMENT 'impound lot id from config',
  PRIMARY KEY (`id`),
  KEY `idx_mdp_impound_plate` (`plate`),
  KEY `idx_mdp_impound_released` (`released`),
  CONSTRAINT `fk_mdp_impound_plate` FOREIGN KEY (`plate`) REFERENCES `mdp_vehicles` (`plate`)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `mdp_fines` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `plate`       VARCHAR(12)  NOT NULL,
  `owner`       VARCHAR(64)  NOT NULL,
  `amount`      INT UNSIGNED NOT NULL,
  `reason`      VARCHAR(255) NULL,
  `issued_by`   VARCHAR(64)  NULL,
  `channel`     ENUM('internal','invoice','external','needs_review') NOT NULL DEFAULT 'internal' COMMENT 'internal=payFine; invoice=billing with paid hook; needs_review=bill sent but not linked; external=reserved, unused for fines',
  `paid`        TINYINT      NOT NULL DEFAULT 0 COMMENT '0=unpaid, 1=paid, 2=claiming, 3=voided (Constants.FineStatus)',
  `created_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_mdp_fines_plate` (`plate`),
  KEY `idx_mdp_fines_owner` (`owner`),
  KEY `idx_mdp_fines_paid` (`paid`)
  -- no FK to mdp_vehicles (v4): fines are tied to `owner` and must survive vehicle removal/sale
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Invoice -> fine mapping used by billing adapters (bridge/billing/_common.lua also creates it at runtime).
-- Columns/types match _common.lua (fine_id INT UNSIGNED). Deleting a fine removes its invoice links.
CREATE TABLE IF NOT EXISTS `mdp_fine_invoices` (
  `provider`    VARCHAR(32)  NOT NULL,
  `invoice_id`  VARCHAR(64)  NOT NULL,
  `fine_id`     INT UNSIGNED NOT NULL,
  PRIMARY KEY (`provider`, `invoice_id`),
  KEY `idx_mdp_fine_invoices_fine` (`fine_id`),
  CONSTRAINT `fk_mdp_fine_invoices_fine` FOREIGN KEY (`fine_id`) REFERENCES `mdp_fines` (`id`)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- v5: identifiers mdp has synced at least once (imported-row adoption: only later incremental syncs are adoptable).
CREATE TABLE IF NOT EXISTS `mdp_synced_owners` (
  `identifier`      VARCHAR(64) NOT NULL,
  `first_synced_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- v5: key/value meta flags (e.g. 'initial_import_done').
CREATE TABLE IF NOT EXISTS `mdp_meta` (
  `k`          VARCHAR(64)  NOT NULL,
  `v`          VARCHAR(255) NULL,
  `updated_at` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`k`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Schema version for idempotent future ALTERs (phase N migrations check/insert their version).
CREATE TABLE IF NOT EXISTS `mdp_schema_version` (
  `version`     INT UNSIGNED NOT NULL,
  `applied_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT IGNORE INTO `mdp_schema_version` (`version`) VALUES (1), (2), (3), (4), (5), (6);
-- v2: mdp_vehicles.vtype. v3: mdp_vehicles.source. v4: no FK mdp_fines -> mdp_vehicles; state 5 REMOVED. Existing v1 installs are upgraded automatically on resource start
-- (server/persistence.lua) or manually with sql/upgrade_v2.sql.
