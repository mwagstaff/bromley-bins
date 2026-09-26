import { readFileSync } from 'node:fs';

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
    addressRateLimit: 20,
    collectionRateLimit: 60
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
            addresses: positiveInteger(env.BINS_ADDRESS_RATE_LIMIT, DEFAULTS.addressRateLimit, 'BINS_ADDRESS_RATE_LIMIT'),
            collections: positiveInteger(env.BINS_COLLECTION_RATE_LIMIT, DEFAULTS.collectionRateLimit, 'BINS_COLLECTION_RATE_LIMIT')
        }),
        // Caddy / Tailscale sit in front on loopback; trust them for req.ip.
        trustProxy: env.BINS_TRUST_PROXY?.trim() || 'loopback'
    });
}
