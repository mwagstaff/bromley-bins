import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from 'prom-client';

export function createMetrics({ collectDefaults = true } = {}) {
    const registry = new Registry();
    registry.setDefaultLabels({ service: 'bromley-bins-api' });
    if (collectDefaults) collectDefaultMetrics({ register: registry });

    return {
        registry,
        httpRequests: new Counter({
            name: 'bins_http_requests_total',
            help: 'API requests by route and response status',
            labelNames: ['route', 'status'],
            registers: [registry]
        }),
        httpDuration: new Histogram({
            name: 'bins_http_request_duration_seconds',
            help: 'API request duration by route',
            labelNames: ['route'],
            buckets: [0.005, 0.025, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
            registers: [registry]
        }),
        upstreamDuration: new Histogram({
            name: 'bins_upstream_request_duration_seconds',
            help: 'Council upstream request duration by operation and outcome',
            labelNames: ['council', 'operation', 'outcome'],
            buckets: [0.1, 0.25, 0.5, 1, 2, 4, 8, 12],
            registers: [registry]
        }),
        upstreamFailures: new Counter({
            name: 'bins_upstream_failures_total',
            help: 'Council upstream failures, including parser failures, by reason',
            labelNames: ['council', 'operation', 'reason'],
            registers: [registry]
        }),
        cacheRequests: new Counter({
            name: 'bins_cache_requests_total',
            help: 'Cache lookups by result (hit, miss, stale, error)',
            labelNames: ['cache', 'result'],
            registers: [registry]
        }),
        cacheEntries: new Gauge({
            name: 'bins_cache_entries',
            help: 'Entries currently held per cache',
            labelNames: ['cache'],
            registers: [registry]
        }),
        rateLimited: new Counter({
            name: 'bins_rate_limited_total',
            help: 'Requests rejected by the rate limiter',
            labelNames: ['route'],
            registers: [registry]
        })
    };
}
