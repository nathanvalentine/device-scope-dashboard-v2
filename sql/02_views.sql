-- ============================================================
-- DeviceScope Normalization Views
-- ============================================================
-- This file is the ONLY place boolean coercion, health derivation,
-- duplicate-flag computation, and patch-status logic should live.
-- Neither the PowerShell collectors nor streamlit_app.py should
-- re-derive any of this. If a rule needs to change, it changes here.
--
-- Re-run this file after every schema change. It only creates views,
-- so it is always safe to DROP + CREATE on every deploy.
-- ============================================================

-- ------------------------------------------------------------
-- Step 1: latest row per device per source (in case a source's
-- raw table accumulates multiple run_ids before cleanup; the
-- "current" picture is always the most recent successful pull)
-- ------------------------------------------------------------

DROP VIEW IF EXISTS v_entra_latest;
CREATE VIEW v_entra_latest AS
SELECT e.*
FROM entra_raw e
WHERE e.pulled_at = (SELECT MAX(pulled_at) FROM entra_raw);

DROP VIEW IF EXISTS v_intune_latest;
CREATE VIEW v_intune_latest AS
SELECT i.*
FROM intune_raw i
WHERE i.pulled_at = (SELECT MAX(pulled_at) FROM intune_raw);

DROP VIEW IF EXISTS v_ad_latest;
CREATE VIEW v_ad_latest AS
SELECT a.*
FROM ad_raw a
WHERE a.pulled_at = (SELECT MAX(pulled_at) FROM ad_raw);

DROP VIEW IF EXISTS v_sophos_latest;
CREATE VIEW v_sophos_latest AS
SELECT s.*
FROM sophos_raw s
WHERE s.pulled_at = (SELECT MAX(pulled_at) FROM sophos_raw);

DROP VIEW IF EXISTS v_kace_latest;
CREATE VIEW v_kace_latest AS
SELECT k.*
FROM kace_raw k
WHERE k.pulled_at = (SELECT MAX(pulled_at) FROM kace_raw);

DROP VIEW IF EXISTS v_eventsentry_latest;
CREATE VIEW v_eventsentry_latest AS
SELECT es.*
FROM eventsentry_raw es
WHERE es.pulled_at = (SELECT MAX(pulled_at) FROM eventsentry_raw);

-- ------------------------------------------------------------
-- Step 2: per-source instance counts and duplicate flags
-- (one row per name_key, regardless of how many raw rows existed)
-- ------------------------------------------------------------

DROP VIEW IF EXISTS v_entra_agg;
CREATE VIEW v_entra_agg AS
SELECT
    name_key,
    COUNT(*)                                                AS entra_instance_count,
    SUM(CASE WHEN trust_type = 'ServerAd' OR join_type LIKE '%Hybrid%' THEN 1 ELSE 0 END)     AS entra_hybrid_count,
    SUM(CASE WHEN trust_type = 'Workplace' OR join_type LIKE '%Registered%' THEN 1 ELSE 0 END) AS entra_registered_count,
    GROUP_CONCAT(DISTINCT device_id)                          AS entra_device_ids,

    -- Device IDs specifically from rows classified as Hybrid (not
    -- Registered or Other) - needed because hybrid-joined devices are
    -- expected to have Entra.DeviceId == the on-prem AD object's
    -- ObjectGUID. Comparing against ALL device_ids (entra_device_ids
    -- above, which includes Registered-type IDs too) would be
    -- comparing apples to oranges - a Registered device's ID has no
    -- reason to match an AD GUID at all, so it must never be lumped
    -- into this comparison.
    GROUP_CONCAT(DISTINCT CASE WHEN trust_type = 'ServerAd' OR join_type LIKE '%Hybrid%' THEN device_id END)
                                                               AS entra_hybrid_device_ids,
    COUNT(DISTINCT CASE WHEN (trust_type = 'ServerAd' OR join_type LIKE '%Hybrid%') AND device_id IS NOT NULL
                         THEN device_id END)                   AS entra_hybrid_distinct_id_count,

    MAX(operating_system)                                     AS operating_system,
    MAX(operating_system_version)                              AS operating_system_version,
    MAX(join_type)                                            AS join_type,
    MAX(is_managed)                                           AS is_managed,
    MAX(is_compliant)                                          AS is_compliant,
    MAX(approx_last_signin)                                    AS approx_last_signin,
    MAX(device_id)                                            AS device_id,
    MAX(display_name)                                          AS display_name,
    MAX(trust_type)                                            AS trust_type
FROM v_entra_latest
GROUP BY name_key;

DROP VIEW IF EXISTS v_intune_agg;
CREATE VIEW v_intune_agg AS
SELECT
    name_key,
    COUNT(*)                       AS intune_instance_count,
    MAX(device_id)                  AS intune_device_id,
    MAX(compliance_state)            AS compliance_state,
    MAX(management_agent)            AS management_agent,
    GROUP_CONCAT(DISTINCT azure_ad_device_id) AS intune_azure_ad_device_ids,
    MAX(last_sync_datetime)           AS last_sync_datetime,
    MAX(operating_system)            AS operating_system,
    MAX(user_principal_name)          AS user_principal_name,
    MAX(serial_number)               AS serial_number
FROM v_intune_latest
GROUP BY name_key;

DROP VIEW IF EXISTS v_sophos_agg;
CREATE VIEW v_sophos_agg AS
SELECT
    name_key,
    COUNT(*)                       AS sophos_instance_count,
    GROUP_CONCAT(DISTINCT sophos_id)  AS sophos_ids,
    MAX(hostname)                   AS hostname,
    MAX(os_name)                    AS os_name,
    MAX(last_seen_at)                AS last_seen_at,
    MAX(health_overall)              AS health_overall,
    MAX(ipv4_addresses)              AS ipv4_addresses,
    MAX(associated_person_name)       AS associated_person_name,
    MAX(device_type)                AS device_type
FROM v_sophos_latest
GROUP BY name_key;

DROP VIEW IF EXISTS v_ad_agg;
CREATE VIEW v_ad_agg AS
SELECT
    name_key,
    COUNT(*)              AS ad_instance_count,
    MAX(ad_name)            AS ad_name,
    MAX(dns_hostname)        AS dns_hostname,
    MAX(operating_system)    AS operating_system,
    MAX(last_logon_date)     AS last_logon_date,
    MAX(enabled)            AS enabled,
    MAX(object_guid)        AS object_guid,
    MAX(location_from_ou)    AS location_from_ou,
    MAX(physical_delivery_office) AS physical_delivery_office
FROM v_ad_latest
GROUP BY name_key;

DROP VIEW IF EXISTS v_kace_agg;
CREATE VIEW v_kace_agg AS
SELECT
    name_key,
    COUNT(*)          AS kace_instance_count,
    MAX(kace_id)        AS kace_id,
    MAX(os_name)        AS os_name,
    MAX(ip_address)     AS ip_address,
    MAX(ram_total)      AS ram_total,
    MAX(last_inventory)  AS last_inventory,
    MAX(service_tag)     AS service_tag,
    MAX(location)       AS location,
    MAX(user_name)      AS user_name
FROM v_kace_latest
GROUP BY name_key;

DROP VIEW IF EXISTS v_eventsentry_agg;
CREATE VIEW v_eventsentry_agg AS
SELECT
    name_key,
    MAX(agent_version)        AS agent_version,
    MAX(inventory_timestamp)    AS inventory_timestamp,

    -- inventory_timestamp arrives as MM/DD/YYYY HH:MM:SS text (same
    -- .NET-formatting issue as eventsentry_patches_raw.install_date -
    -- see v_patch_agg note below). Converted to ISO 8601 here so any
    -- julianday() math downstream (EventSentry_Stale, EventSentry_AgeDays
    -- in v_devices_unified) gets a parseable value instead of silently
    -- returning NULL. Raw inventory_timestamp is kept above, unchanged,
    -- for display purposes (EventSentry_InventoryTimestamp).
    MAX(
        CASE
            WHEN inventory_timestamp IS NOT NULL AND length(inventory_timestamp) >= 19
                THEN substr(inventory_timestamp, 7, 4) || '-' || substr(inventory_timestamp, 1, 2) || '-' ||
                     substr(inventory_timestamp, 4, 2) || ' ' || substr(inventory_timestamp, 12, 8)
            ELSE NULL
        END
    )                         AS inventory_timestamp_iso,

    MAX(manufacturer)         AS manufacturer,
    MAX(model)               AS model,
    MAX(os)                  AS os,
    MAX(total_memory)         AS total_memory,
    MAX(bitlocker)            AS bitlocker,
    MAX(uptime)               AS uptime,
    MAX(is_vm)                AS is_vm,
    MAX(chassis_type)         AS chassis_type,
    MAX(product_type)         AS product_type
FROM v_eventsentry_latest
GROUP BY name_key;

-- ------------------------------------------------------------
-- Step 3: patch status aggregation (most recent install date per
-- device across all Microsoft security/cumulative updates seen)
-- ------------------------------------------------------------

-- NOTE: install_date arrives from the EventSentry collector as
-- MM/DD/YYYY HH:MM:SS text (.NET default ToString() formatting on
-- the collector host), NOT SQLite's expected YYYY-MM-DD. Two bugs
-- result if used as-is:
--   1. MAX() on the raw text sorts lexicographically, not
--      chronologically - e.g. "12/13/2025" > "01/05/2026" as text,
--      even though Jan 2026 is the later date. This silently picks
--      the wrong "most recent patch" date for some devices.
--   2. julianday() cannot parse MM/DD/YYYY at all and returns NULL,
--      which made every device with patch data fall through to the
--      'Critical' ELSE branch downstream, and every device without
--      a join match show 'Unknown' - i.e. patch status was actually
--      reporting "EventSentry had a value or it didn't", not real
--      recency at all (Current/Behind counts were stuck at 0).
-- Fix: rewrite to YYYY-MM-DD HH:MM:SS before MAX()/julianday() ever
-- see it. Guarded by length check so an unexpectedly-shaped value
-- becomes NULL (-> 'Unknown') instead of a corrupted ISO string.
DROP VIEW IF EXISTS v_patch_agg;
CREATE VIEW v_patch_agg AS
SELECT
    name_key,
    MAX(
        CASE
            WHEN install_date IS NOT NULL AND length(install_date) >= 19
                THEN substr(install_date, 7, 4) || '-' || substr(install_date, 1, 2) || '-' ||
                     substr(install_date, 4, 2) || ' ' || substr(install_date, 12, 8)
            ELSE NULL
        END
    )                 AS last_patch_install_date,
    COUNT(*)          AS patch_records_seen

    -- A Cumulative-Update-specific breakout (matching security_update
    -- LIKE '%Cumulative Update%') and a Security-Update-specific
    -- breakout (LIKE '%Security Update%') were both attempted and
    -- removed. security_update (despite the column name, inherited
    -- from the collector's PostgreSQL alias - see
    -- Get-EventSentryDevices.ps1's $sqlPatches query, which aliases
    -- esappname.name AS securityupdate) holds the update title text,
    -- but this source is EventSentry's general application inventory
    -- (a QFE/Get-HotFix-style source), not the rich Windows Update
    -- Catalog. Confirmed against real production data: titles never
    -- contain "Cumulative", and the "Security Update (KBxxxxxxx)"
    -- title convention is itself legacy (~2016-era Windows) - modern
    -- Windows 10/11/Server 2016+ rolls security fixes into the single
    -- monthly update without that title wording at all. A title-based
    -- breakout by update category isn't reliably recoverable from
    -- this data source for the actively-used modern fleet; the plain
    -- last_patch_install_date above (no title filtering) is the
    -- trustworthy signal - it just means "device installed *some*
    -- Microsoft update recently," which in practice is driven by the
    -- monthly updates without depending on any particular title
    -- convention holding up across OS versions.
FROM eventsentry_patches_raw
WHERE publisher LIKE 'Microsoft%'
GROUP BY name_key;

-- ------------------------------------------------------------
-- Step 4: the unified device view. One row per name_key, all
-- sources joined, all presence flags + booleans normalized here.
-- ------------------------------------------------------------

DROP VIEW IF EXISTS v_devices_unified;
CREATE VIEW v_devices_unified AS
WITH all_keys AS (
    SELECT name_key FROM v_entra_agg
    UNION SELECT name_key FROM v_intune_agg
    UNION SELECT name_key FROM v_ad_agg
    UNION SELECT name_key FROM v_sophos_agg
    UNION SELECT name_key FROM v_kace_agg
    UNION SELECT name_key FROM v_eventsentry_agg
)
SELECT
    ak.name_key                                              AS Name,

    -- ---- normalized presence booleans (single source of truth) ----
    (e.name_key IS NOT NULL)                                  AS InEntra,
    (i.name_key IS NOT NULL)                                  AS InIntune,
    (a.name_key IS NOT NULL)                                  AS InAD,
    (s.name_key IS NOT NULL)                                  AS InSophos,
    (k.name_key IS NOT NULL)                                  AS InKACE,
    (es.name_key IS NOT NULL)                                 AS InEventSentry,

    -- ---- personal/unmanaged device detection (roadmap item #6) ----
    -- Entra-only, nothing else => personal/MAM-managed mobile device.
    -- Used to gate EventSentry relevance instead of OS-string guessing.
    -- Broadened beyond pure "Entra-only": a personal/BYOD phone can
    -- also be Intune-enrolled (common for company email/app access on
    -- a personal device) while still never being a Windows endpoint
    -- EventSentry could realistically monitor. Mobile OS strings
    -- (Android, iOS, iPhone, iPadOS) are treated as personal even
    -- when Intune presence alone would otherwise mark the device
    -- "corporate." Real corporate Windows laptops that are Entra+
    -- Intune are unaffected - they fail the OS check and still fall
    -- through to the original i.name_key IS NULL requirement.
    (e.name_key IS NOT NULL
        AND a.name_key IS NULL
        AND s.name_key IS NULL
        AND k.name_key IS NULL
        AND (
            i.name_key IS NULL
            OR LOWER(COALESCE(i.operating_system, e.operating_system, '')) LIKE '%android%'
            OR LOWER(COALESCE(i.operating_system, e.operating_system, '')) LIKE '%ios%'
            OR LOWER(COALESCE(i.operating_system, e.operating_system, '')) LIKE '%iphone%'
            OR LOWER(COALESCE(i.operating_system, e.operating_system, '')) LIKE '%ipad%'
        ))                                                     AS IsPersonalDevice,

    -- A device is "corporate" if it shows up anywhere other than
    -- a personal-Entra-only footprint. NOTE: deliberately does NOT
    -- include InEventSentry - EventSentry presence alone does not
    -- make a device "corporate" here, since EventSentry-only devices
    -- (no AD/Intune/Sophos/KACE footprint) get their own dedicated
    -- "Removal Needed" handling in v_devices_health rather than being
    -- folded into the normal corporate health checks.
    (a.name_key IS NOT NULL OR i.name_key IS NOT NULL
        OR s.name_key IS NOT NULL OR k.name_key IS NOT NULL)    AS IsCorporateDevice,

    -- ---- instance counts / duplicate flags ----
    COALESCE(e.entra_instance_count, 0)                        AS Entra_InstanceCount,
    COALESCE(e.entra_hybrid_count, 0)                          AS Entra_HybridCount,
    COALESCE(e.entra_registered_count, 0)                       AS Entra_RegisteredCount,
    (COALESCE(e.entra_instance_count, 0) > 1
        OR (COALESCE(e.entra_hybrid_count,0) > 0 AND COALESCE(e.entra_registered_count,0) > 0)
        OR COALESCE(e.entra_hybrid_count, 0) > 1)               AS Entra_DuplicateFlag,
    e.entra_device_ids                                         AS Entra_DeviceIds,

    -- ---- Hybrid-joined Entra DeviceId vs AD ObjectGUID reconciliation ----
    -- Ported from AllDeviceExports_Merge.ps1, never carried into any
    -- view during the SQLite rewrite (same situation as DeviceType
    -- and HealthReason before it). For hybrid-joined devices, Entra's
    -- DeviceId is expected to equal the on-prem AD computer object's
    -- ObjectGUID - that's how hybrid join actually works. These two
    -- flags automate that comparison instead of requiring someone to
    -- eyeball long GUID strings against each other (the whole reason
    -- AD_ObjectGUID/Entra_DeviceIds/Intune_AzureADDeviceIds were
    -- grouped together in the Data table in the first place).
    -- Matches: TRUE if at least one hybrid-classified Entra DeviceId
    -- equals the device's AD ObjectGUID. The delimited LIKE pattern
    -- here is an exact-element check against the comma-joined list,
    -- not a substring match - safe because GUIDs contain only hex
    -- digits and hyphens, never commas, so there's no ambiguity about
    -- where one element ends and the next begins.
    CASE
        WHEN a.object_guid IS NULL OR e.entra_hybrid_device_ids IS NULL THEN 0
        WHEN (',' || e.entra_hybrid_device_ids || ',') LIKE ('%,' || a.object_guid || ',%') THEN 1
        ELSE 0
    END                                                          AS Entra_HybridIdMatchesAD,

    -- Mismatch Exists: TRUE if at least one hybrid-classified Entra
    -- DeviceId does NOT equal the AD ObjectGUID. Not mutually
    -- exclusive with Matches above - a device with two distinct
    -- hybrid Entra DeviceIds (itself a duplicate-join problem) could
    -- have one that matches AD and one that doesn't, which should
    -- show both flags as TRUE simultaneously, exactly like the
    -- original PowerShell logic allowed.
    CASE
        WHEN COALESCE(e.entra_hybrid_distinct_id_count, 0) = 0 THEN 0
        WHEN e.entra_hybrid_distinct_id_count > 1 THEN 1
        WHEN a.object_guid IS NULL THEN 1
        WHEN e.entra_hybrid_device_ids != a.object_guid THEN 1
        ELSE 0
    END                                                          AS Entra_HybridIdMismatchExists,

    COALESCE(i.intune_instance_count, 0)                        AS Intune_InstanceCount,
    (COALESCE(i.intune_instance_count, 0) > 1)                   AS Intune_DuplicateFlag,
    i.intune_azure_ad_device_ids                                AS Intune_AzureADDeviceIds,

    COALESCE(s.sophos_instance_count, 0)                        AS Sophos_InstanceCount,
    (COALESCE(s.sophos_instance_count, 0) > 1)                   AS Sophos_DuplicateFlag,
    s.sophos_ids                                               AS Sophos_Ids,

    -- Overall multi-instance flag: any source has duplicates
    (COALESCE(e.entra_instance_count,0) > 1
        OR COALESCE(i.intune_instance_count,0) > 1
        OR COALESCE(s.sophos_instance_count,0) > 1)              AS MultiInstanceFlag,

    -- ---- device descriptive fields (priority: AD/Sophos/KACE over Entra) ----
    COALESCE(i.operating_system, e.operating_system, a.operating_system, s.os_name, k.os_name) AS OS,
    COALESCE(i.serial_number, k.service_tag)                     AS SerialNumber,
    COALESCE(i.user_principal_name, s.associated_person_name, k.user_name) AS PrimaryUser,
    COALESCE(a.location_from_ou, k.location)                     AS Location,
    COALESCE(i.last_sync_datetime, s.last_seen_at, e.approx_last_signin, k.last_inventory) AS LastSeen,
    -- Memory (RAM), in whole GB for display - was previously raw MB
    -- with no unit conversion at all (e.g. 16131 instead of 16), and
    -- sourced EventSentry-first/KACE-second. Both fixed here:
    --   1. SQLite's CAST(text AS REAL) parses the leading numeric
    --      prefix and ignores the rest, so '16384 Bytes' (KACE's
    --      actual raw text, mislabeled - it's really MB, the same
    --      unit EventSentry reports, not literal bytes) and '16131'
    --      (EventSentry's raw text) both cast cleanly to MB values
    --      without any string-stripping gymnastics.
    --   2. Source priority flipped to KACE-first: EventSentry's agent
    --      has proven unreliable in this environment (see the stub-
    --      record and staleness issues elsewhere in this file), so
    --      KACE - which inventories hardware specs directly and isn't
    --      subject to the same agent-health problems - is the more
    --      trustworthy source when both are present.
    CASE
        WHEN COALESCE(
                 CASE WHEN k.ram_total IS NOT NULL AND TRIM(k.ram_total) != '' THEN CAST(k.ram_total AS REAL) END,
                 CASE WHEN es.total_memory IS NOT NULL AND TRIM(es.total_memory) != '' THEN CAST(es.total_memory AS REAL) END
             ) IS NULL THEN NULL
        ELSE CAST(ROUND(
                 COALESCE(
                     CASE WHEN k.ram_total IS NOT NULL AND TRIM(k.ram_total) != '' THEN CAST(k.ram_total AS REAL) END,
                     CASE WHEN es.total_memory IS NOT NULL AND TRIM(es.total_memory) != '' THEN CAST(es.total_memory AS REAL) END
                 ) / 1024.0
             ) AS INTEGER)
    END                                                            AS Memory,

    -- ---- Device type, ported from AllDeviceExports_Merge.ps1's Get-DeviceType ----
    -- This lived only in the old PowerShell CSV-merge script and was
    -- never carried into any collector or view during the SQLite
    -- rewrite - dropped entirely, same situation as HealthReason
    -- before it. Priority order preserved from the original except
    -- one deliberate consolidation: the original had two separate
    -- mobile-ish outcomes - "Mobile" (OS string matched iOS/Android/
    -- iPhone/iPad) and "Mobile/Personal" (Entra-registered + isolated
    -- from every other source) - but given the OS-string check was
    -- evaluated first, "Mobile/Personal" almost never actually fired
    -- in practice (any device reporting a real mobile OS string was
    -- already claimed by "Mobile"). Merged into one "Mobile/Personal"
    -- bucket, since in this environment phones are never tracked
    -- through any source but Entra anyway - ownership/lack of
    -- management is the meaningful distinction here, not OS. One
    -- side effect worth knowing: a hypothetical Entra-registered,
    -- otherwise-isolated device reporting a Windows OS string would
    -- now land in Mobile/Personal too, rather than falling through to
    -- the Windows/Desktop fallback below - that's intentional once
    -- this bucket means "personal/unmanaged" rather than "is a phone."
    CASE
        WHEN es.is_vm = 1
            THEN 'Virtual Machine'
        WHEN a.operating_system LIKE '%Server%'
             OR s.device_type LIKE 'server'
             OR es.product_type LIKE 'SERVER'
            THEN 'Server'
        WHEN es.chassis_type LIKE '%Laptop%' OR es.chassis_type LIKE '%Notebook%'
             OR es.chassis_type LIKE '%Portable%' OR es.chassis_type LIKE '%Book%'
            THEN 'Laptop'
        WHEN a.ad_name LIKE 'LAPTOP-%' OR e.display_name LIKE 'LAPTOP-%'
            THEN 'Laptop'
        WHEN es.chassis_type LIKE '%Tower%' OR es.chassis_type LIKE '%Desktop%'
            THEN 'Desktop'
        WHEN (COALESCE(es.os, '') || ' ' || COALESCE(e.operating_system, '') || ' ' || COALESCE(k.os_name, ''))
             LIKE '%iOS%'
             OR (COALESCE(es.os, '') || ' ' || COALESCE(e.operating_system, '') || ' ' || COALESCE(k.os_name, ''))
             LIKE '%Android%'
             OR (COALESCE(es.os, '') || ' ' || COALESCE(e.operating_system, '') || ' ' || COALESCE(k.os_name, ''))
             LIKE '%iPhone%'
             OR (COALESCE(es.os, '') || ' ' || COALESCE(e.operating_system, '') || ' ' || COALESCE(k.os_name, ''))
             LIKE '%iPad%'
            THEN 'Mobile/Personal'
        WHEN (e.trust_type = 'Workplace' OR e.join_type LIKE '%Registered%')
             AND a.name_key IS NULL AND k.name_key IS NULL
             AND s.name_key IS NULL AND es.name_key IS NULL
             AND e.name_key IS NOT NULL
            THEN 'Mobile/Personal'
        WHEN (COALESCE(es.os, '') || ' ' || COALESCE(e.operating_system, '') || ' ' || COALESCE(k.os_name, ''))
             LIKE '%Windows%'
            THEN 'Desktop'
        ELSE 'Unknown'
    END                                                          AS DeviceType,


    -- ---- identity / compliance snapshot fields ----
    e.device_id                                                AS Entra_DeviceId,
    -- join_type alone left this blank for hybrid-joined SERVER objects
    -- (synced via AD Connect) - Microsoft Graph populates trust_type
    -- ('ServerAd', 'Workplace', etc.) for those but often leaves
    -- join_type empty, since "join type" as a concept is more
    -- meaningful for client devices. Falling back to trust_type
    -- covers that case without changing anything for devices where
    -- join_type IS populated (e.g. typical client Hybrid/Registered
    -- join_type text), since COALESCE only reaches for trust_type
    -- when join_type itself is NULL.
    COALESCE(e.join_type, e.trust_type)                          AS Entra_JoinType,
    e.operating_system_version                                  AS Entra_OperatingSystemVersion,
    e.is_managed                                                AS Entra_IsManaged,
    e.is_compliant                                              AS Entra_IsCompliant,

    i.intune_device_id                                          AS Intune_DeviceId,
    i.compliance_state                                          AS Intune_ComplianceState,
    i.management_agent                                          AS Intune_ManagementAgent,

    a.ad_name                                                   AS AD_Name,
    a.dns_hostname                                               AS AD_DNSHostName,
    a.last_logon_date                                            AS AD_LastLogonDate,
    a.enabled                                                   AS AD_Enabled,
    a.object_guid                                                AS AD_ObjectGUID,

    s.hostname                                                  AS Sophos_Hostname,
    s.health_overall                                             AS Sophos_Health,
    s.ipv4_addresses                                             AS Sophos_ipv4Addresses,

    k.kace_id                                                   AS KACE_ID,
    k.ip_address                                                 AS KACE_Machine_Ip,
    k.ram_total                                                  AS KACE_Machine_RAM_Total,
    k.last_inventory                                              AS KACE_LastInventory,

    -- ---- Physical branch location, derived from IP subnet ----
    -- Ported from the original CSV-based app's SUBNET_TO_BRANCH dict /
    -- get_branch_from_ip() helper. IP address (KACE_Machine_Ip only -
    -- the original never fell back to Sophos's IP) is the only real
    -- source of truth for *physical* location; AD's OU path or KACE's
    -- "location" field reflect directory/asset-tag organization, which
    -- can drift from where a device actually sits on the network. LIKE
    -- with a literal (non-wildcard) prefix behaves identically to
    -- Python's str.startswith() - safe here because every subnet below
    -- is octet-aligned with a trailing dot, so no prefix can accidentally
    -- match a different subnet (e.g. '10.157.1.' vs '10.157.15.' differ
    -- at the dot boundary, not just numerically).
    CASE
        WHEN k.ip_address IS NULL OR TRIM(k.ip_address) = '' THEN NULL
        WHEN k.ip_address LIKE '10.157.0.%'  THEN 'Logan Production'
        WHEN k.ip_address LIKE '10.157.1.%'  THEN 'Logan Production'
        WHEN k.ip_address LIKE '10.157.15.%' THEN 'Logan Administration'
        WHEN k.ip_address LIKE '10.157.16.%' THEN 'Mortgage'
        WHEN k.ip_address LIKE '10.157.18.%' THEN 'South Logan'
        WHEN k.ip_address LIKE '10.157.20.%' THEN 'Hyrum'
        WHEN k.ip_address LIKE '10.157.21.%' THEN 'Ogden'
        WHEN k.ip_address LIKE '10.157.22.%' THEN 'Smithfield'
        WHEN k.ip_address LIKE '10.157.23.%' THEN 'Logan Mall'
        WHEN k.ip_address LIKE '10.157.24.%' THEN 'SLC'
        WHEN k.ip_address LIKE '10.157.26.%' THEN 'Preston'
        WHEN k.ip_address LIKE '10.157.27.%' THEN 'Cedar City'
        WHEN k.ip_address LIKE '10.157.29.%' THEN 'Lehi'
        WHEN k.ip_address LIKE '10.157.41.%' THEN 'Washington'
        WHEN k.ip_address LIKE '10.157.42.%' THEN 'Sunset'
        WHEN k.ip_address LIKE '10.157.43.%' THEN 'River Road'
        WHEN k.ip_address LIKE '10.157.44.%' THEN 'Layton'
        WHEN k.ip_address LIKE '10.157.46.%' THEN 'DR'
        WHEN k.ip_address LIKE '10.157.47.%' THEN 'North Logan'
        WHEN k.ip_address LIKE '10.157.48.%' THEN 'Logan Main'
        WHEN k.ip_address LIKE '10.157.49.%' THEN 'Logan Main'
        WHEN k.ip_address LIKE '10.157.50.%' THEN 'Logan Printers'
        WHEN k.ip_address LIKE '10.157.51.%' THEN 'Fairview'
        WHEN k.ip_address LIKE '10.157.52.%' THEN 'Mount Pleasant'
        WHEN k.ip_address LIKE '10.157.53.%' THEN 'Loa'
        WHEN k.ip_address LIKE '10.157.54.%' THEN 'Bountiful'
        WHEN k.ip_address LIKE '10.157.55.%' THEN 'Price'
        WHEN k.ip_address LIKE '10.157.56.%' THEN 'Nephi'
        WHEN k.ip_address LIKE '10.157.57.%' THEN 'Ephraim'
        WHEN k.ip_address LIKE '10.157.58.%' THEN 'Tabernacle'
        WHEN k.ip_address LIKE '10.157.59.%' THEN 'Tabernacle'
        ELSE 'Unknown'
    END                                                            AS BranchLocation,

    -- ---- EventSentry fields + normalized agent-present boolean ----
    es.agent_version                                             AS EventSentry_AgentVersion,
    es.inventory_timestamp                                       AS EventSentry_InventoryTimestamp,
    es.manufacturer                                               AS EventSentry_Manufacturer,
    es.model                                                     AS EventSentry_Model,
    es.os                                                       AS EventSentry_OS,
    es.total_memory                                               AS EventSentry_TotalMemory,
    es.bitlocker                                                  AS EventSentry_BitLocker,
    es.uptime                                                     AS EventSentry_Uptime,
    (es.agent_version IS NOT NULL AND TRIM(es.agent_version) != '')  AS EventSentry_AgentPresent,

    -- EventSentry staleness (agent present, but inventory > 7 days old).
    -- Uses inventory_timestamp_iso (converted in v_eventsentry_agg),
    -- NOT the raw inventory_timestamp - see note there. A NULL ISO
    -- value (no timestamp, or unparseable text) is treated as stale
    -- rather than healthy, matching the "Unknown" fallback used for
    -- patch status.
    CASE
        WHEN es.agent_version IS NULL OR TRIM(es.agent_version) = '' THEN 0
        WHEN es.inventory_timestamp_iso IS NULL THEN 1
        WHEN julianday('now') - julianday(es.inventory_timestamp_iso) > 7 THEN 1
        ELSE 0
    END                                                          AS EventSentry_Stale,

    CASE
        WHEN es.inventory_timestamp_iso IS NULL THEN NULL
        ELSE CAST(ROUND(julianday('now') - julianday(es.inventory_timestamp_iso), 0) AS INTEGER)
    END                                                          AS EventSentry_AgeDays,

    -- ---- patch status (roadmap: EventSentry security update data) ----
    -- Personal/mobile devices (same definition as IsPersonalDevice -
    -- repeated inline since SQLite can't reference a sibling SELECT
    -- alias within the same query) get 'Not Applicable' rather than
    -- 'Unknown'. They were never going to have EventSentry patch data
    -- in the first place - EventSentry doesn't run on phones - so
    -- lumping them into 'Unknown' alongside corporate devices that
    -- genuinely lack EventSentry coverage made the Patch Management
    -- tab's Unknown count look like a bigger fleet-wide visibility gap
    -- than it actually is. 'Not Applicable' is excluded from the
    -- Patch Management tab's 4 tracked buckets entirely (Current/
    -- Behind/Critical/Unknown), so these devices simply don't appear
    -- there rather than inflating any of them.
    p.last_patch_install_date                                    AS LastPatchInstallDate,
    CASE
        WHEN e.name_key IS NOT NULL
             AND a.name_key IS NULL
             AND s.name_key IS NULL
             AND k.name_key IS NULL
             AND (
                 i.name_key IS NULL
                 OR LOWER(COALESCE(i.operating_system, e.operating_system, '')) LIKE '%android%'
                 OR LOWER(COALESCE(i.operating_system, e.operating_system, '')) LIKE '%ios%'
                 OR LOWER(COALESCE(i.operating_system, e.operating_system, '')) LIKE '%iphone%'
                 OR LOWER(COALESCE(i.operating_system, e.operating_system, '')) LIKE '%ipad%'
             )
            THEN 'Not Applicable'
        WHEN p.last_patch_install_date IS NULL THEN 'Unknown'
        WHEN julianday('now') - julianday(p.last_patch_install_date) <= 30 THEN 'Current'
        WHEN julianday('now') - julianday(p.last_patch_install_date) <= 60 THEN 'Behind'
        ELSE 'Critical'
    END                                                          AS PatchStatus,
    CASE
        WHEN p.last_patch_install_date IS NULL THEN NULL
        ELSE CAST(ROUND(julianday('now') - julianday(p.last_patch_install_date), 0) AS INTEGER)
    END                                                          AS DaysSinceLastPatch

    -- Title-based breakouts (Cumulative Update, Security Update) were
    -- both attempted and removed - see the comment in v_patch_agg for
    -- why. PatchStatus/DaysSinceLastPatch above is the single,
    -- trustworthy patch-currency signal: it doesn't depend on any
    -- update-title convention holding up across OS versions, just on
    -- "was *some* Microsoft update installed recently."

FROM all_keys ak
LEFT JOIN v_entra_agg e        ON e.name_key = ak.name_key
LEFT JOIN v_intune_agg i       ON i.name_key = ak.name_key
LEFT JOIN v_ad_agg a           ON a.name_key = ak.name_key
LEFT JOIN v_sophos_agg s       ON s.name_key = ak.name_key
LEFT JOIN v_kace_agg k         ON k.name_key = ak.name_key
LEFT JOIN v_eventsentry_agg es ON es.name_key = ak.name_key
LEFT JOIN v_patch_agg p        ON p.name_key = ak.name_key;

-- ------------------------------------------------------------
-- Step 5: anomaly + health derivation, gated correctly for
-- personal devices (roadmap item #6 fix lives here)
-- ------------------------------------------------------------

DROP VIEW IF EXISTS v_devices_health;
CREATE VIEW v_devices_health AS
SELECT
    du.*,

    -- "Relevant" for EventSentry checks only if it's a real corporate
    -- device, i.e. NOT a personal/MAM-only Entra device.
    (du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0)        AS IsEventSentryRelevant,

    -- Active elsewhere = present in any non-EventSentry corporate source.
    -- Retained for reference, but no longer used to gate the
    -- missing-agent or stale-agent anomalies below (see notes there).
    (du.InIntune = 1 OR du.InEntra = 1 OR du.InAD = 1)            AS IsActiveElsewhere,

    -- EventSentry-only device: present in EventSentry but in NO other
    -- source at all (not even KACE). EventSentry is corporate-only -
    -- it should never be the SOLE record of a device's existence.
    -- A device in this state has almost always been decommissioned,
    -- reimaged under a new name, or otherwise retired from every
    -- other system, but the EventSentry agent/record was never
    -- cleaned up. These get their own "Removal Needed" status below
    -- instead of being evaluated against the normal corporate health
    -- rules (IsCorporateDevice is FALSE for these devices by design -
    -- see the note on IsCorporateDevice in v_devices_unified - so
    -- without this flag they would silently fall through every other
    -- check as if nothing were wrong).
    (du.InEventSentry = 1
        AND du.InEntra = 0 AND du.InIntune = 0 AND du.InAD = 0
        AND du.InSophos = 0 AND du.InKACE = 0)                   AS IsEventSentryOnly,

    -- EventSentry "stub" record: InEventSentry=TRUE (a row exists in
    -- eventsentry_raw, sourced from EventSentry's eseventlogcomputer
    -- table) but agent_version is NULL - i.e. no matching essysinfo
    -- row was ever joined. EventSentry's eseventlogcomputer table
    -- tracks any host EventSentry has seen send Windows Event Log
    -- data (passive log collection, WMI probing, discovery scans),
    -- which is NOT the same as having a reporting EventSentry agent
    -- (that requires an essysinfo row, where agent_version actually
    -- lives). These devices are real and do exist in EventSentry's
    -- database, but won't appear in the Management Console or Web
    -- Reports, which are driven by essysinfo-backed inventory. This
    -- is distinct from "truly missing" (no eventsentry_raw row at
    -- all) - see Anomaly_ES_MissingWhileActive below, which now
    -- excludes this case so the two aren't conflated under one
    -- Critical bucket.
    -- Gated on IsPersonalDevice=0 for the same reason as the two
    -- anomaly flags below - in practice a true personal device will
    -- never have an eventsentry_raw row at all (EventSentry doesn't
    -- run on phones), so this is a defensive/consistency gate rather
    -- than one that's expected to change real-world behavior.
    (du.InEventSentry = 1 AND du.EventSentry_AgentPresent = 0
        AND du.IsPersonalDevice = 0)                              AS EventSentry_StubRecordOnly,

    -- Missing EventSentry agent: ANY corporate, non-personal device
    -- with no EventSentry agent AND no EventSentry record at all
    -- (InEventSentry = 0). Devices with a stub eseventlogcomputer
    -- record but no agent (EventSentry_StubRecordOnly = 1) are
    -- intentionally excluded here - they get their own lower-urgency
    -- "Informational" status below rather than Critical, since many
    -- of these are DMZ servers of unconfirmed monitoring intent
    -- rather than confirmed coverage gaps. Previously this also
    -- required (InIntune OR InEntra OR InAD), which meant a device
    -- present only in KACE could never trip this anomaly even though
    -- it's clearly a real corporate device missing agent coverage -
    -- that part of the fix from the prior session is retained.
    CASE
        WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
             AND du.EventSentry_AgentPresent = 0
             AND du.InEventSentry = 0
        THEN 1 ELSE 0
    END                                                          AS Anomaly_ES_MissingWhileActive,

    -- Stale EventSentry agent: ANY corporate, non-personal device with
    -- a present-but-stale agent gets flagged, regardless of whether it
    -- also shows up in Entra/Intune/AD. Previously this required
    -- (InIntune OR InEntra OR InAD), which meant KACE-only-and-
    -- EventSentry devices (e.g. loaner laptops) could go stale forever
    -- without ever tripping this anomaly. Name retained for backward
    -- compatibility even though it's no longer "WhileActive"-gated.
    CASE
        WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
             AND du.EventSentry_AgentPresent = 1
             AND du.EventSentry_Stale = 1
        THEN 1 ELSE 0
    END                                                          AS Anomaly_ES_StaleWhileActive,

    -- Composite health status (same rule order as previous Python impl,
    -- plus the new EventSentry-only "Removal Needed" case checked
    -- FIRST since it overrides/preempts the normal corporate checks -
    -- a device in this state isn't really "corporate" by the
    -- IsCorporateDevice definition, so it would otherwise fall through
    -- to '✅ Healthy' by default, which is actively misleading).
    CASE
        WHEN du.InEventSentry = 1
             AND du.InEntra = 0 AND du.InIntune = 0 AND du.InAD = 0
             AND du.InSophos = 0 AND du.InKACE = 0
            THEN '🧹 Removal Needed'
        WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
             AND du.InEventSentry = 1 AND du.EventSentry_AgentPresent = 0
            THEN 'ℹ️ Informational'
        WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
             AND du.EventSentry_AgentPresent = 0
            THEN '🚨 Critical'
        WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
             AND du.EventSentry_AgentPresent = 1 AND du.EventSentry_Stale = 1
            THEN '⚠ Warning'
        WHEN du.MultiInstanceFlag = 1
            THEN '⚠ Warning'
        WHEN du.InSophos = 1 AND du.Sophos_Health IS NOT NULL
             AND LOWER(du.Sophos_Health) NOT IN ('healthy','good','')
            THEN '⚠ Warning'
        ELSE '✅ Healthy'
    END                                                          AS DeviceHealth,

    -- HealthReason: human-readable explanation of why DeviceHealth is
    -- what it is. EventSentry-only case is checked first and returns
    -- immediately (mutually exclusive with the other fragments below,
    -- since a device with no footprint anywhere else can't also have
    -- Entra/Intune/Sophos duplicate instances or a Sophos health
    -- value). The remaining fragments are unchanged in structure from
    -- before, just no longer requiring Entra/Intune/AD presence for
    -- the EventSentry fragments - see the two anomaly CASE expressions
    -- above for that rationale.
    CASE
        WHEN du.InEventSentry = 1
             AND du.InEntra = 0 AND du.InIntune = 0 AND du.InAD = 0
             AND du.InSophos = 0 AND du.InKACE = 0
            THEN 'Device exists only in EventSentry and has been removed from all other systems - should be removed from EventSentry'
        WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
             AND du.InEventSentry = 1 AND du.EventSentry_AgentPresent = 0
            THEN 'In EventSentry computer list but no agent installed - install agent or confirm monitoring not needed'
        WHEN (
            (CASE WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
                       AND du.EventSentry_AgentPresent = 0
                  THEN '; Missing EventSentry agent' ELSE '' END) ||
            (CASE WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
                       AND du.EventSentry_AgentPresent = 1 AND du.EventSentry_Stale = 1
                  THEN '; EventSentry data is stale' ELSE '' END) ||
            (CASE WHEN du.MultiInstanceFlag = 1
                  THEN '; Duplicate device detected across systems' ELSE '' END) ||
            (CASE WHEN du.InSophos = 1 AND du.Sophos_Health IS NOT NULL
                       AND LOWER(du.Sophos_Health) NOT IN ('healthy','good','')
                  THEN '; Sophos health is ''' || du.Sophos_Health || '''' ELSE '' END)
        ) = '' THEN 'No issues detected'
        ELSE SUBSTR(
            (CASE WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
                       AND du.EventSentry_AgentPresent = 0
                  THEN '; Missing EventSentry agent' ELSE '' END) ||
            (CASE WHEN du.IsCorporateDevice = 1 AND du.IsPersonalDevice = 0
                       AND du.EventSentry_AgentPresent = 1 AND du.EventSentry_Stale = 1
                  THEN '; EventSentry data is stale' ELSE '' END) ||
            (CASE WHEN du.MultiInstanceFlag = 1
                  THEN '; Duplicate device detected across systems' ELSE '' END) ||
            (CASE WHEN du.InSophos = 1 AND du.Sophos_Health IS NOT NULL
                       AND LOWER(du.Sophos_Health) NOT IN ('healthy','good','')
                  THEN '; Sophos health is ''' || du.Sophos_Health || '''' ELSE '' END),
            3
        )
    END                                                          AS HealthReason

FROM v_devices_unified du;

-- ------------------------------------------------------------
-- Step 6: final consumer-facing view, with notes joined in.
-- This is the ONLY view streamlit_app.py should query for the
-- main data table and device overview.
-- ------------------------------------------------------------

DROP VIEW IF EXISTS v_devices_final;
CREATE VIEW v_devices_final AS
SELECT
    dh.*,
    n.note,
    n.status        AS NoteStatus,
    n.updated_by,
    n.updated_at     AS NoteUpdatedAt
FROM v_devices_health dh
LEFT JOIN device_notes n
    ON n.device_key = COALESCE('GUID:' || dh.AD_ObjectGUID, 'NAME:' || dh.Name);