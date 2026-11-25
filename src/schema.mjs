/**
 * Version of the machine-readable output (`--json`). Bump this only for a
 * breaking shape change: removing or retyping a field. Additive fields do not
 * bump it. Consumers are expected to ignore unknown keys and tolerate the
 * documented nullable values; test/report-json.test.mjs pins the rest.
 */
export const JSON_SCHEMA_VERSION = 1;
