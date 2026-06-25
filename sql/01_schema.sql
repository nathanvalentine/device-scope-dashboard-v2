-- ============================================================
-- DeviceScope SQLite Schema
-- Raw per-source tables + persistent notes + normalization views
-- ============================================================
-- Design principles:
--   1. Each source owns one raw table. A failed pull simply does
--      not replace that table's rows (handled in PowerShell, not SQL).
--   2. device_notes is NEVER touched by the daily import. It is
--      keyed on AD_ObjectGUID (stable across renames) with device
--      name retained only for display/fallback joins.
--   3. All normalization (bools, health, duplicates, patch status)
--      lives in views below. Streamlit and PowerShell never
--      re-derive these fields themselves.
-- ============================================================

PRAGMA foreign_keys = ON;

-- ------------------------------------------------------------
-- Raw source tables (one row per device per source, except
-- duplicates which legitimately produce multiple rows)
-- ------------------------------------------------------------

DROP TABLE IF EXISTS entra_raw;
CREATE TABLE entra_raw (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    name_key            TEXT NOT NULL,
    device_id           TEXT,
    display_name        TEXT,
    operating_system     TEXT,
    operating_system_version TEXT,
    trust_type          TEXT,
    join_type            TEXT,
    is_managed          TEXT,
    is_compliant         TEXT,
    approx_last_signin   TEXT,
    pulled_at            TEXT NOT NULL,
    source_run_id        TEXT NOT NULL
);
CREATE INDEX idx_entra_raw_namekey ON entra_raw(name_key);
CREATE INDEX idx_entra_raw_run ON entra_raw(source_run_id);

DROP TABLE IF EXISTS intune_raw;
CREATE TABLE intune_raw (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    name_key            TEXT NOT NULL,
    device_id           TEXT,
    device_name          TEXT,
    operating_system     TEXT,
    compliance_state     TEXT,
    management_agent     TEXT,
    azure_ad_device_id   TEXT,
    serial_number        TEXT,
    user_principal_name   TEXT,
    last_sync_datetime    TEXT,
    pulled_at            TEXT NOT NULL,
    source_run_id        TEXT NOT NULL
);
CREATE INDEX idx_intune_raw_namekey ON intune_raw(name_key);
CREATE INDEX idx_intune_raw_run ON intune_raw(source_run_id);

DROP TABLE IF EXISTS ad_raw;
CREATE TABLE ad_raw (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    name_key            TEXT NOT NULL,
    ad_name              TEXT,
    dns_hostname          TEXT,
    operating_system     TEXT,
    last_logon_date      TEXT,
    enabled              TEXT,
    object_guid          TEXT,
    distinguished_name    TEXT,
    ou_name              TEXT,
    ou_path              TEXT,
    location_from_ou      TEXT,
    physical_delivery_office TEXT,
    pulled_at            TEXT NOT NULL,
    source_run_id        TEXT NOT NULL
);
CREATE INDEX idx_ad_raw_namekey ON ad_raw(name_key);
CREATE INDEX idx_ad_raw_guid ON ad_raw(object_guid);
CREATE INDEX idx_ad_raw_run ON ad_raw(source_run_id);

DROP TABLE IF EXISTS sophos_raw;
CREATE TABLE sophos_raw (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    name_key            TEXT NOT NULL,
    sophos_id            TEXT,
    hostname             TEXT,
    os_name              TEXT,
    last_seen_at          TEXT,
    health_overall        TEXT,
    ipv4_addresses        TEXT,
    device_type           TEXT,
    associated_person_name TEXT,
    pulled_at            TEXT NOT NULL,
    source_run_id        TEXT NOT NULL
);
CREATE INDEX idx_sophos_raw_namekey ON sophos_raw(name_key);
CREATE INDEX idx_sophos_raw_run ON sophos_raw(source_run_id);

DROP TABLE IF EXISTS kace_raw;
CREATE TABLE kace_raw (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    name_key            TEXT NOT NULL,
    kace_id              TEXT,
    kace_name             TEXT,
    os_name              TEXT,
    ip_address            TEXT,
    ram_used              TEXT,
    ram_total             TEXT,
    last_inventory        TEXT,
    service_tag           TEXT,
    location              TEXT,
    user_name             TEXT,
    pulled_at            TEXT NOT NULL,
    source_run_id        TEXT NOT NULL
);
CREATE INDEX idx_kace_raw_namekey ON kace_raw(name_key);
CREATE INDEX idx_kace_raw_run ON kace_raw(source_run_id);

DROP TABLE IF EXISTS eventsentry_raw;
CREATE TABLE eventsentry_raw (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    name_key            TEXT NOT NULL,
    hostname             TEXT,
    agent_version          TEXT,
    inventory_timestamp     TEXT,
    manufacturer           TEXT,
    model                 TEXT,
    os                   TEXT,
    os_edition             TEXT,
    total_memory           TEXT,
    bitlocker             TEXT,
    uptime                TEXT,
    chassis_type           TEXT,
    product_type           TEXT,
    is_vm                 INTEGER,
    pulled_at            TEXT NOT NULL,
    source_run_id        TEXT NOT NULL
);
CREATE INDEX idx_eventsentry_raw_namekey ON eventsentry_raw(name_key);
CREATE INDEX idx_eventsentry_raw_run ON eventsentry_raw(source_run_id);

-- Patch detail, one row per update per device (Option A aggregation
-- happens in the view layer below; we keep raw rows for future
-- "show full patch history" capability per the design discussion)
DROP TABLE IF EXISTS eventsentry_patches_raw;
CREATE TABLE eventsentry_patches_raw (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    name_key            TEXT NOT NULL,
    hostname             TEXT,
    publisher             TEXT,
    security_update        TEXT,
    version               TEXT,
    is_64bit              INTEGER,
    install_date           TEXT,
    pulled_at            TEXT NOT NULL,
    source_run_id        TEXT NOT NULL
);
CREATE INDEX idx_es_patches_namekey ON eventsentry_patches_raw(name_key);
CREATE INDEX idx_es_patches_run ON eventsentry_patches_raw(source_run_id);

-- ------------------------------------------------------------
-- Pipeline run metadata: tracks success/failure per source per run.
-- This is what makes "fall back to yesterday's data" possible and
-- what powers the freshness indicator in Streamlit.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS source_run_log;
CREATE TABLE source_run_log (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    source_name           TEXT NOT NULL,         -- 'Entra','Intune','AD','Sophos','KACE','EventSentry'
    run_id               TEXT NOT NULL,          -- shared run identifier for a whole pipeline execution
    status               TEXT NOT NULL,          -- 'Success','Failed','SkippedUsedCache'
    row_count             INTEGER,
    error_message          TEXT,
    started_at            TEXT NOT NULL,
    completed_at           TEXT
);
CREATE INDEX idx_run_log_source ON source_run_log(source_name);
CREATE INDEX idx_run_log_run ON source_run_log(run_id);

-- ------------------------------------------------------------
-- Persistent, user-curated notes. NEVER truncated by import.
-- Keyed on AD_ObjectGUID for rename-resilience; device_name kept
-- only as a fallback display/join aid for devices with no AD presence.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS device_notes;
CREATE TABLE device_notes (
    device_key           TEXT PRIMARY KEY,   -- AD_ObjectGUID if available, else 'NAME:<name_key>'
    device_name_hint       TEXT,               -- last known display name, for human readability only
    note                 TEXT,
    status               TEXT DEFAULT 'New',  -- 'New' | 'Acknowledged' | 'Resolved'
    updated_by            TEXT,
    updated_at            TEXT
);
