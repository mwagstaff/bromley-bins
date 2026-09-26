import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { createApp } from '../lib/app.js';
import { BinsService } from '../lib/bins/bins-service.js';
import { WasteWorksProvider } from '../lib/bins/wasteworks-provider.js';
import { createMetrics } from '../lib/metrics.js';
import { fakeFetch, fixture } from './helpers.js';

let server;
let baseUrl;
let upstream;

before(async () => {
    upstream = fakeFetch({
        'POST /waste': (init) => new Response(
            init.body === 'postcode=BR1+1AA'
                ? fixture('wasteworks-address-results.html')
                : fixture('wasteworks-address-none.html')
        ),
        'GET /waste/3642936/calendar.ics': () => new Response(fixture('wasteworks-calendar.ics')),
        'GET /waste/5/calendar.ics': () => new Response('<html>Service unavailable</html>'),
        'GET /waste/9999999999/calendar.ics': () => new Response('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n')
    });
    const metrics = createMetrics({ collectDefaults: false });
    const provider = new WasteWorksProvider({
        council: 'bromley',
        baseUrl: 'https://recyclingservices.bromley.gov.uk/',
        userAgent: 'test',
        fetchImpl: upstream,
        metrics
    });
    const app = createApp({
        service: new BinsService({ provider, metrics }),
        metrics,
        rateLimitConfig: { windowMs: 60_000, addresses: 5, collections: 100 }
    });
    server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

const get = async (path) => {
    const response = await fetch(`${baseUrl}${path}`);
    return { status: response.status, body: await response.json(), headers: response.headers };
};

test('GET /api/bins/addresses returns normalised addresses', async () => {
    const { status, body } = await get('/api/bins/addresses?postcode=br11aa');
    assert.equal(status, 200);
    assert.equal(body.postcode, 'BR1 1AA');
    assert.equal(body.addresses.length, 6);
    assert.deepEqual(Object.keys(body.addresses[0]).sort(), ['address', 'propertyId']);
});

test('address lookup errors', async () => {
    assert.deepEqual((await get('/api/bins/addresses?postcode=zzz')).body.error.code, 'INVALID_POSTCODE');
    assert.equal((await get('/api/bins/addresses')).status, 400);
    const none = await get('/api/bins/addresses?postcode=SW1A1AA');
    assert.equal(none.status, 404);
    assert.equal(none.body.error.code, 'NO_ADDRESSES_FOUND');
});

test('GET /api/bins/:propertyId/collections returns the schedule', async () => {
    const { status, body } = await get('/api/bins/3642936/collections');
    assert.equal(status, 200);
    assert.equal(body.propertyId, '3642936');
    assert.equal(body.stale, false);
    assert.match(body.lastUpdated, /^\d{4}-\d{2}-\d{2}T/);
    assert.equal(body.collections.length, 32);
    assert.deepEqual(Object.keys(body.collections[0]).sort(), ['date', 'label', 'normalizedType', 'type']);
});

test('collection errors', async () => {
    assert.equal((await get('/api/bins/abc/collections')).body.error.code, 'INVALID_PROPERTY_ID');
    const notFound = await get('/api/bins/9999999999/collections');
    assert.equal(notFound.status, 404);
    assert.equal(notFound.body.error.code, 'PROPERTY_NOT_FOUND');
    const broken = await get('/api/bins/5/collections');
    assert.equal(broken.status, 502);
    assert.equal(broken.body.error.code, 'UPSTREAM_ERROR');
    assert.doesNotMatch(JSON.stringify(broken.body), /html|NOT_VCALENDAR/i);
});

test('unknown routes 404 and nothing proxies arbitrary upstream paths', async () => {
    const before = upstream.calls.length;
    assert.equal((await get('/api/bins/3642936/calendar.ics')).status, 404);
    assert.equal((await get('/waste/3642936')).status, 404);
    assert.equal(upstream.calls.length, before);
});

test('rate-limits address lookups per client', async () => {
    let last;
    for (let i = 0; i < 8; i += 1) last = await get('/api/bins/addresses?postcode=BR1%201AA');
    assert.equal(last.status, 429);
    assert.equal(last.body.error.code, 'RATE_LIMITED');
    assert.ok(Number(last.headers.get('retry-after')) > 0);
});

test('healthcheck and metrics', async () => {
    assert.deepEqual((await get('/healthcheck')).body, { status: 'ok' });
    const metrics = await (await fetch(`${baseUrl}/metrics`)).text();
    assert.match(metrics, /bins_cache_requests_total\{cache="collections",result="miss"[^}]*\} \d+/);
    assert.match(metrics, /bins_http_requests_total\{route="\/api\/bins\/:propertyId\/collections",status="502"/);
});
