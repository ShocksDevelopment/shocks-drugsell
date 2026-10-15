-- SHOCKS Drug Selling reputation table.
-- This is included for reference/manual setup. server.lua runs the same
-- CREATE TABLE IF NOT EXISTS automatically when the resource starts.

CREATE TABLE IF NOT EXISTS `shocks_drugsell_reputation` (
    `citizenid` VARCHAR(64) NOT NULL,
    `xp` INT UNSIGNED NOT NULL DEFAULT 0,
    `level` TINYINT UNSIGNED NOT NULL DEFAULT 1,
    `sales` INT UNSIGNED NOT NULL DEFAULT 0,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`),
    KEY `idx_drugsell_level` (`level`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
