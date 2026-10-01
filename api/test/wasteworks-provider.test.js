import assert from 'node:assert/strict';
import { test } from 'node:test';
import { WasteWorksProvider } from '../lib/bins/wasteworks-provider.js';
import { ParserError, UpstreamError } from '../lib/errors.js';
import { createMetrics } from '../lib/metrics.js';
import { calendar, fakeFetch } from './helpers.js';

function provider(routes, options = {}) {
    const fetchImpl = fakeFetch(routes);
    return {
        fetchImpl,
        provider: new WasteWorksProvider({
            council: 'bromley',
            baseUrl: 'https://recyclingservices.bromley.gov.uk/',
            userAgent: 'BromleyBins/test',
            fetchImpl,
            ...options
        })
    };
}

test('fetches the property calendar', async () => {
    const { provider: p, fetchImpl } = provider({
        'GET /waste/3642936/calendar.ics': () => new Response(calendar({ start: '20261002', summary: 'Food Waste collection' }))
    });
    assert.equal((await p.getCollections('3642936')).length, 1);
    assert.equal(fetchImpl.calls[0].init.headers.Accept, 'text/calendar,text/plain');
});

test('refuses non-numeric property IDs before any request', async () => {
    const { provider: p, fetchImpl } = provider({});
    await assert.rejects(p.getCollections('../admin'), TypeError);
    assert.equal(fetchImpl.calls.length, 0);
});

test('maps HTTP failures, network failures and timeouts', async () => {
    const metrics = createMetrics({ collectDefaults: false });
    const { provider: p } = provider({
        'GET /waste/1/calendar.ics': () => new Response('down', { status: 503 }),
        'GET /waste/2/calendar.ics': () => { throw new TypeError('fetch failed'); },
        'GET /waste/3/calendar.ics': () => { throw new DOMException('timed out', 'TimeoutError'); },
        'GET /waste/4/calendar.ics': () => new Response('<html>oops</html>')
    }, { metrics });

    await assert.rejects(p.getCollections('1'), (e) => e instanceof UpstreamError && e.code === 'UPSTREAM_ERROR' && e.httpStatus === 503);
    await assert.rejects(p.getCollections('2'), (e) => e.code === 'UPSTREAM_ERROR' && e.reason === 'NETWORK');
    await assert.rejects(p.getCollections('3'), (e) => e.code === 'UPSTREAM_TIMEOUT' && e.status === 504);
    await assert.rejects(p.getCollections('4'), (e) => e instanceof ParserError && e.reason === 'NOT_VCALENDAR');

    const text = await metrics.registry.metrics();
    assert.match(text, /bins_upstream_failures_total\{council="bromley",operation="get_collections",reason="TIMEOUT"[^}]*\} 1/);
    assert.match(text, /bins_upstream_request_duration_seconds_count\{[^}]*operation="get_collections",outcome="parse_error"\} 1/);
});

test('times out a hung upstream request', async () => {
    const hanging = (init) => new Promise((_, reject) => {
        init.signal.addEventListener('abort', () => reject(init.signal.reason));
    });
    const { provider: p } = provider({ 'GET /waste/1/calendar.ics': hanging }, { timeoutMs: 20 });
    await assert.rejects(p.getCollections('1'), (e) => e.code === 'UPSTREAM_TIMEOUT');
});
