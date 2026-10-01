import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

/** Councils we know how to talk to. Only Bromley is served today. */
export const COUNCILS = Object.freeze({
    bromley: Object.freeze({
        council: 'bromley',
        provider: 'wasteworks',
        baseUrl: 'https://recyclingservices.bromley.gov.uk/'
    })
});

const DEFAULTS = Object.freeze({
    port: 3040,
    host: '0.0.0.0',
    council: 'bromley',
    upstreamTimeoutMs: 10_000,
    rateLimitWindowMs: 60_000,
    collectionRateLimit: 60,
    registrationRateLimit: 20,
    testRateLimit: 10,
    bundleId: 'dev.skynolimit.bromleybins',
    apnsRequestTimeoutMs: 10_000
});

function positiveInteger(value, fallback, name, { maximum = Number.MAX_SAFE_INTEGER } = {}) {
    if (value === undefined || value === '') return fallback;
    const parsed = Number(value);
    if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > maximum) {
        throw new Error(`${name} must be a positive integer no greater than ${maximum}`);
    }
    return parsed;
}

export function loadConfig(env = process.env) {
    const councilKey = env.BINS_COUNCIL?.trim() || DEFAULTS.council;
    const council = COUNCILS[councilKey];
    if (!council) throw new Error(`Unknown BINS_COUNCIL "${councilKey}"`);

    return Object.freeze({
        version,
        port: positiveInteger(env.PORT, DEFAULTS.port, 'PORT', { maximum: 65_535 }),
        host: env.HOST?.trim() || DEFAULTS.host,
        council,
        userAgent: `BromleyBins/${version} (+https://skynolimit.dev)`,
        upstreamTimeoutMs: positiveInteger(env.BINS_UPSTREAM_TIMEOUT_MS, DEFAULTS.upstreamTimeoutMs, 'BINS_UPSTREAM_TIMEOUT_MS'),
        rateLimit: Object.freeze({
            windowMs: positiveInteger(env.BINS_RATE_LIMIT_WINDOW_MS, DEFAULTS.rateLimitWindowMs, 'BINS_RATE_LIMIT_WINDOW_MS'),
            collections: positiveInteger(env.BINS_COLLECTION_RATE_LIMIT, DEFAULTS.collectionRateLimit, 'BINS_COLLECTION_RATE_LIMIT'),
            registrations: positiveInteger(env.BINS_REGISTRATION_RATE_LIMIT, DEFAULTS.registrationRateLimit, 'BINS_REGISTRATION_RATE_LIMIT'),
            tests: positiveInteger(env.BINS_TEST_RATE_LIMIT, DEFAULTS.testRateLimit, 'BINS_TEST_RATE_LIMIT')
        }),
        dataDir: env.BINS_DATA_DIR?.trim() || path.join(os.homedir(), '.local/share/bromley-bins-api'),
        push: loadPushConfig(env),
        // Caddy / Tailscale sit in front on loopback; trust them for req.ip.
        trustProxy: env.BINS_TRUST_PROXY?.trim() || 'loopback'
    });
}

/**
 * APNs settings, using the same env names as the estate's other services
 * (APNS_KEY_ID, APNS_TEAM_ID, APNS_AUTH_KEY_PATH or APNS_AUTH_KEY). Without
 * them the API still serves collections but sends no reminders. Each device
 * says whether it needs the sandbox or production APNs host.
 */
function loadPushConfig(env) {
    const keyId = env.APNS_KEY_ID?.trim();
    const teamId = env.APNS_TEAM_ID?.trim();
    const keyPath = env.APNS_AUTH_KEY_PATH?.trim();
    const inlineKey = env.APNS_AUTH_KEY?.trim();
    const configured = [keyId, teamId, keyPath || inlineKey].filter(Boolean).length;
    if (configured === 0) return Object.freeze({ enabled: false });
    if (configured < 3) {
        throw new Error('Push needs all of APNS_KEY_ID, APNS_TEAM_ID and APNS_AUTH_KEY_PATH (or APNS_AUTH_KEY), or none');
    }
    return Object.freeze({
        enabled: true,
        keyId,
        teamId,
        keyPath,
        inlineKey,
        bundleId: env.BINS_APNS_BUNDLE_ID?.trim() || DEFAULTS.bundleId,
        requestTimeoutMs: positiveInteger(env.BINS_APNS_TIMEOUT_MS, DEFAULTS.apnsRequestTimeoutMs, 'BINS_APNS_TIMEOUT_MS')
    });
}
