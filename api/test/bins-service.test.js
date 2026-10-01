import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BinsService, CACHE_DEFAULTS } from '../lib/bins/bins-service.js';
import { UpstreamError } from '../lib/errors.js';
import { manualClock } from './helpers.js';

const HOUR = 60 * 60 * 1_000;
const FOOD = { date: '2026-10-02', type: 'Food Waste collection', label: 'Food Waste', normalizedType: 'food' };

function fakeProvider(overrides = {}) {
    const calls = { getCollections: 0 };
    const provider = {
        async getCollections() {
            calls.getCollections += 1;
            return [FOOD];
        },
        ...overrides
    };
    for (const name of Object.keys(calls)) {
        const original = provider[name];
        if (overrides[name]) {
            provider[name] = (...args) => {
                calls[name] += 1;
                return original(...args);
            };
        }
    }
    return { provider, calls };
}

test('returns collections with lastUpdated and stale=false', async () => {
    const clock = manualClock();
    const service = new BinsService({ provider: fakeProvider().provider, clock });
    assert.deepEqual(await service.getCollections('3642936'), {
        propertyId: '3642936',
        collections: [FOOD],
        lastUpdated: '2026-09-27T12:00:00.000Z',
        stale: false
    });
    await assert.rejects(service.getCollections('abc'), { code: 'INVALID_PROPERTY_ID', status: 400 });
});

test('coalesces concurrent collection requests into one upstream call', async () => {
    const { provider, calls } = fakeProvider();
    const service = new BinsService({ provider });
    await Promise.all(Array.from({ length: 5 }, () => service.getCollections('1')));
    assert.equal(calls.getCollections, 1);
});

test('serves stale collections during an outage, for up to 48 hours past expiry', async () => {
    const clock = manualClock();
    let failing = false;
    const { provider, calls } = fakeProvider({
        getCollections: async () => {
            if (failing) throw new UpstreamError('TIMEOUT', { timeout: true });
            return [FOOD];
        }
    });
    const service = new BinsService({ provider, clock });
    await service.getCollections('1');

    clock.advance(5 * HOUR);
    assert.equal((await service.getCollections('1')).stale, false);
    assert.equal(calls.getCollections, 1);

    failing = true;
    clock.advance(2 * HOUR);
    const stale = await service.getCollections('1');
    assert.equal(stale.stale, true);
    assert.equal(stale.lastUpdated, '2026-09-27T12:00:00.000Z');
    assert.deepEqual(stale.collections, [FOOD]);

    clock.advance(48 * HOUR);
    await assert.rejects(service.getCollections('1'), { code: 'UPSTREAM_TIMEOUT', status: 504 });
});

test('an empty calendar is PROPERTY_NOT_FOUND and is not cached', async () => {
    const { provider, calls } = fakeProvider({ getCollections: async () => [] });
    const service = new BinsService({ provider });
    await assert.rejects(service.getCollections('9999999999'), { code: 'PROPERTY_NOT_FOUND', status: 404 });
    await assert.rejects(service.getCollections('9999999999'), { code: 'PROPERTY_NOT_FOUND' });
    assert.equal(calls.getCollections, 2);
});

test('an empty calendar for a known property does not wipe its schedule', async () => {
    const clock = manualClock();
    let empty = false;
    const { provider } = fakeProvider({ getCollections: async () => (empty ? [] : [FOOD]) });
    const service = new BinsService({ provider, clock });
    await service.getCollections('1');

    empty = true;
    clock.advance(7 * HOUR);
    const result = await service.getCollections('1');
    assert.equal(result.stale, true);
    assert.deepEqual(result.collections, [FOOD]);
});
