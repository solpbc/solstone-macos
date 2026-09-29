// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

pub const BUNDLE_VERSION: &str = "1.1.0";
pub const WIRE_PROTOCOL: u32 = 1;

pub const EXTENSION_TO_HOST_MAX: usize = 33554432;
pub const HOST_TO_EXTENSION_MAX: usize = 65536;
pub const CONTROL_MAX: usize = 65536;
pub const DELTA_RECORDS_MAX: usize = 3000;
pub const BATCH_ID_HEX_LEN: usize = 32;
// Object and array containers count toward depth; the root container counts as one.
pub const JSON_MAX_DEPTH: usize = 127;

pub const FILE_MAX: usize = 50331648;
pub const OUTBOX_BYTES_MAX: usize = 67108864;
pub const OUTBOX_AGE_MS_MAX: u64 = 600000;
pub const SPOOL_BYTES_MAX: usize = 536870912;
pub const SPOOL_AGE_MS_MAX: u64 = 604800000;
pub const FUTURE_SKEW_MS_MAX: u64 = 60000;
pub const ACCEPTED_RETENTION_MS_MIN: u64 = 1200000;
pub const HANDSHAKE_MS_BUDGET: u64 = 5000;
pub const STATE_RENEWAL_MS_INTERVAL: u64 = 5000;
pub const FRESHNESS_MS_MAX: u64 = 15000;
pub const PARTIAL_FRAME_MS_LIFETIME: u64 = 30000;
pub const TIMESTAMP_MAX: u64 = 9007199254740991;

pub const VERSION_MAX: usize = 64;
pub const GENERATION_MAX: usize = 128;
pub const PERIOD_ID_MAX: usize = 128;
pub const FAILURE_CODE_MAX: usize = 64;

pub const INST_STRING_MAX: usize = 128;
pub const ID_STRING_MAX: usize = 256;
pub const TITLE_STRING_MAX: usize = 8192;
pub const URL_STRING_MAX: usize = 32768;
pub const SITE_STRING_MAX: usize = 512;
pub const ADAPTER_STRING_MAX: usize = 64;
pub const CTX_STRING_MAX: usize = 256;
pub const TYPE_STRING_MAX: usize = 64;
pub const LINK_HOST_STRING_MAX: usize = 512;
pub const LEVEL_STRING_MAX: usize = 16;
pub const LABEL_STRING_MAX: usize = 300;
pub const TEXT_MAX: usize = 2001;
pub const BLOCK_DEPTH_MAX: u64 = 4096;
pub const BLOCKS_MAX: usize = 1500;

pub const BRAND_ENUM: &[&str] = &["chrome", "edge", "firefox"];
pub const CAPTURE_ENUM: &[&str] = &["unavailable", "not_paired", "permitted", "paused", "intake_off"];
pub const DELIVERY_ENUM: &[&str] = &["unknown", "kept_locally", "delivered", "idle", "failed"];
pub const FAILURE_ENUM: &[&str] = &["relay_unavailable", "journal_rejected", "local_io", "resource_exhausted", "queue_full", "age_policy", "unaccepted_lost"];
pub const BYE_REASON_ENUM: &[&str] = &["shutdown", "replaced", "update"];
pub const SNAPSHOT_REASON_ENUM: &[&str] = &["delivery_recovery"];
pub const BEHIND_ENUM: &[&str] = &["app", "extension"];

pub const RESULT_ENUM: &[&str] = &["accepted", "duplicate", "rejected"];
pub const RETRYABLE_REASONS: &[&str] = &["snapshot_required", "resource_exhausted", "queue_full", "age_policy"];
pub const PERMANENT_REASONS: &[&str] = &["malformed", "oversize", "stale_generation", "expired_unaccepted", "unaccepted_lost"];
pub const REGISTRATION_JSON: &str = r#"{"description":"Solstone browser host","type":"stdio","path_placeholder":"__PATH__","suffixes":{"chrome_linux":".config/google-chrome/NativeMessagingHosts/<host>.json","edge_linux":".config/microsoft-edge/NativeMessagingHosts/<host>.json","firefox_linux":".mozilla/native-messaging-hosts/<host>.json","chrome_macos":"Library/Application Support/Google/Chrome/NativeMessagingHosts/<host>.json","edge_macos":"Library/Application Support/Microsoft Edge/NativeMessagingHosts/<host>.json","firefox_macos":"Library/Application Support/Mozilla/NativeMessagingHosts/<host>.json","chrome_windows":"Software\\Google\\Chrome\\NativeMessagingHosts\\<host>","edge_windows":"Software\\Microsoft\\Edge\\NativeMessagingHosts\\<host>","firefox_windows":"Software\\Mozilla\\NativeMessagingHosts\\<host>"},"argv":{"chrome_macos":{"arguments_after_executable":["origin"],"identity_argument":0,"identity_source":"allowed_origins"},"chrome_linux":{"arguments_after_executable":["origin"],"identity_argument":0,"identity_source":"allowed_origins"},"chrome_windows":{"arguments_after_executable":["origin","parent_window"],"identity_argument":0,"identity_source":"allowed_origins"},"edge_macos":{"arguments_after_executable":["origin"],"identity_argument":0,"identity_source":"allowed_origins"},"edge_linux":{"arguments_after_executable":["origin"],"identity_argument":0,"identity_source":"allowed_origins"},"edge_windows":{"arguments_after_executable":["origin","parent_window"],"identity_argument":0,"identity_source":"allowed_origins"},"firefox_macos":{"arguments_after_executable":["manifest_path","extension_id"],"identity_argument":1,"identity_source":"allowed_extensions"},"firefox_linux":{"arguments_after_executable":["manifest_path","extension_id"],"identity_argument":1,"identity_source":"allowed_extensions"},"firefox_windows":{"arguments_after_executable":["manifest_path","extension_id"],"identity_argument":1,"identity_source":"allowed_extensions"}},"windows":{"hive":"HKEY_CURRENT_USER","value_name":"","value_type":"REG_SZ","value":"absolute_manifest_path","registry_views":["32","64"],"path_contains_view":false}}"#;
pub const CANONICAL_KEY_ORDER_JSON: &str = r#"{"hello":["type","protocol","version","brand","inst"],"hello_ack":["type","capture","delivery","freshness_ms","destination_generation","period_id","failure","custody","version"],"unsupported":["type","protocol","behind"],"state":["type","capture","delivery","freshness_ms","destination_generation","period_id","failure","custody","version"],"batch":["type","destination_generation","inst","batch_id","queued_at_ms","records"],"boundary":["type","destination_generation","period_id"],"accepted":["type","result","destination_generation","inst","batch_id","period_id","reason","class"],"bye":["type","reason"],"snapshot_record":["t","ts","rel","site","url","title","adapter","ctx","inst","n","blocks","snapshot_reason"],"delta_record":["t","ts","rel","site","ctx","inst","op","block"],"block":["id","text","type","depth","attrs"],"block_attrs":["label","level","linkHost"]}"#;

pub const REGISTRATION_DESCRIPTION: &str = "Solstone browser host";
pub const REGISTRATION_TYPE: &str = "stdio";
pub const REGISTRATION_PATH_PLACEHOLDER: &str = "__PATH__";

pub const PROD_HOST: &str = "app.solstone.browser";
pub const PROD_CHROME_ID: &str = "eibbeeoifjoabddfmgeggnageolkcnim";
pub const PROD_EDGE_ID: &str = "eibbeeoifjoabddfmgeggnageolkcnim";
pub const PROD_FIREFOX_ID: &str = "browser@solstone.app";

pub const DEV_HOST: &str = "app.solstone.browser.dev";
pub const DEV_CHROME_ID: &str = "fgfnkcefedeheoeamppkiiloncfekakf";
pub const DEV_EDGE_ID: &str = "fgfnkcefedeheoeamppkiiloncfekakf";
pub const DEV_FIREFOX_ID: &str = "browser.dev@solstone.app";
