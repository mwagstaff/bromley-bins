import assert from 'node:assert/strict';
import { mkdtemp, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { createApp } from '../lib/app.js';
import { BinsService } from '../lib/bins/bins-service.js';
import { WasteWorksProvider } from '../lib/bins/wasteworks-provider.js';
import { createMetrics } from '../lib/metrics.js';
import { DeviceStore } from '../lib/reminders/device-store.js';
import { fakeFetch, fixture } from './helpers.js';

const INSTALLATION = '0f8fad5b-d9cb-469f-a165-70867728950e';
const TOKEN = 'a'.repeat(64);

let server;
let baseUrl;
let store;
let dataDir;
const testsSent = [];

before(async () => {
    const upstream = fakeFetch({
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
    dataDir = await mkdtemp(path.join(os.tmpdir(), 'bins-app-'));
    store = await new DeviceStore({ dataDir }).load();
    const scheduler = {
        tick() {},
        async sendTest(device, test) {
            testsSent.push({ device: device.installationId, test });
        }
    };
    const app = createApp({
        service: new BinsService({ provider, metrics }),
        store,
        scheduler,
        metrics,
        rateLimitConfig: { windowMs: 60_000, collections: 100, registrations: 100, tests: 4 }
    });
    server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

const call = async (method, urlPath, body) => {
    const response = await fetch(`${baseUrl}${urlPath}`, {
        method,
        headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body))
    });
    const text = await response.text();
    return { status: response.status, body: text ? JSON.parse(text) : null };
};

const registration = (overrides = {}) => ({
    apnsToken: TOKEN,
    liveActivityToken: 'b'.repeat(64),
    environment: 'sandbox',
    propertyId: '3642936',
    reminders: { enabled: true, hour: 19, minute: 0, showsLiveActivity: true },
    hiddenTypes: [],
    ...overrides
});

test('GET /api/bins/:propertyId/collections returns the schedule', async () => {
    const { status, body } = await call('GET', '/api/bins/3642936/collections');
    assert.equal(status, 200);
    assert.equal(body.propertyId, '3642936');
    assert.equal(body.stale, false);
    assert.equal(body.collections.length, 32);
    assert.deepEqual(Object.keys(body.collections[0]).sort(), ['date', 'label', 'normalizedType', 'type']);
});

test('collection errors', async () => {
    assert.equal((await call('GET', '/api/bins/abc/collections')).body.error.code, 'INVALID_PROPERTY_ID');
    assert.equal((await call('GET', '/api/bins/9999999999/collections')).body.error.code, 'PROPERTY_NOT_FOUND');
    const broken = await call('GET', '/api/bins/5/collections');
    assert.equal(broken.status, 502);
    assert.doesNotMatch(JSON.stringify(broken.body), /html|NOT_VCALENDAR/i);
});

test('the server offers no postcode, address or UPRN lookups', async () => {
    assert.equal((await call('GET', '/api/bins/addresses?postcode=BR1%201AA')).status, 404);
    assert.equal((await call('GET', '/api/bins/uprn/100020437397')).status, 404);
});

test('registers, updates and deletes a device', async () => {
    const created = await call('PUT', `/api/devices/${INSTALLATION}`, registration());
    assert.equal(created.status, 200);
    assert.deepEqual(created.body, { registered: true, remindersEnabled: true });
    assert.equal(store.get(INSTALLATION).propertyId, '3642936');

    await call('PUT', `/api/devices/${INSTALLATION.toUpperCase()}`, registration({ hiddenTypes: ['Food Waste collection'] }));
    assert.deepEqual(store.get(INSTALLATION).hiddenTypes, ['Food Waste collection']);
    assert.equal(store.size, 1);

    const saved = JSON.parse(await readFile(path.join(dataDir, 'devices.json'), 'utf8'));
    assert.equal(saved.length, 1);
    assert.doesNotMatch(JSON.stringify(saved), /postcode|address/i);

    assert.equal((await call('DELETE', `/api/devices/${INSTALLATION}`)).status, 204);
    assert.equal(store.get(INSTALLATION), undefined);
});

test('rejects invalid registrations', async () => {
    const put = (body, id = INSTALLATION) => call('PUT', `/api/devices/${id}`, body);
    assert.equal((await put(registration(), 'not-a-uuid')).body.error.code, 'INVALID_INSTALLATION_ID');
    for (const bad of [
        registration({ apnsToken: 'zz', liveActivityToken: null }),
        registration({ apnsToken: null, liveActivityToken: null }),
        registration({ environment: 'staging' }),
        registration({ propertyId: '../x' }),
        registration({ reminders: { enabled: true, hour: 24, minute: 0, showsLiveActivity: true } }),
        registration({ hiddenTypes: 'food' }),
        { postcode: 'BR1 1AA' }
    ]) {
        const response = await put(bad);
        assert.equal(response.status, 400, JSON.stringify(bad));
        assert.equal(response.body.error.code, 'INVALID_REGISTRATION');
    }
    assert.equal((await put('{not json')).body.error.code, 'INVALID_BODY');
    assert.equal((await put(registration({ propertyId: '9999999999' }))).body.error.code, 'PROPERTY_NOT_FOUND');
    assert.equal(store.size, 0);
});

test('test reminders are for sandbox (debug) registrations only and rate limited', async () => {
    const test = { items: [{ label: 'Food Waste', type: 'food' }], phase: 'eveningBefore', delaySeconds: 5, send: 'both' };
    assert.equal((await call('POST', `/api/devices/${INSTALLATION}/test`, test)).body.error.code, 'NOT_REGISTERED');

    await call('PUT', `/api/devices/${INSTALLATION}`, registration({ environment: 'production' }));
    assert.equal((await call('POST', `/api/devices/${INSTALLATION}/test`, test)).status, 403);

    await call('PUT', `/api/devices/${INSTALLATION}`, registration());
    assert.equal((await call('POST', `/api/devices/${INSTALLATION}/test`, { ...test, delaySeconds: 9999 })).status, 400);
    assert.equal((await call('POST', `/api/devices/${INSTALLATION}/test`, test)).status, 202);
    assert.deepEqual(testsSent, [{ device: INSTALLATION, test: { ...test, staleAfterSeconds: null } }]);
    assert.equal((await call('POST', `/api/devices/${INSTALLATION}/test`, test)).status, 429);
    await call('DELETE', `/api/devices/${INSTALLATION}`);
});

test('healthcheck and metrics', async () => {
    assert.deepEqual((await call('GET', '/healthcheck')).body, { status: 'ok' });
    const metrics = await (await fetch(`${baseUrl}/metrics`)).text();
    assert.match(metrics, /bins_http_requests_total\{route="PUT \/api\/devices\/:installationId",status="200"/);
});
