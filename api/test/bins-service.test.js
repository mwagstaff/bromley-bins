import assert from 'node:assert/strict';
import { test } from 'node:test';
import { BinsService, CACHE_DEFAULTS } from '../lib/bins/bins-service.js';
import { ParserError, UpstreamError } from '../lib/errors.js';
import { manualClock } from './helpers.js';

const HOUR = 60 * 60 * 1_000;
const FOOD = { date: '2026-10-02', type: 'Food Waste collection', label: 'Food Waste', normalizedType: 'food' };

function fakeProvider(overrides = {}) {
    const calls = { lookupAddresses: 0, getCollections: 0, resolveUPRN: 0 };
    const provider = {
        async lookupAddresses() {
            calls.lookupAddresses += 1;
            return [{ propertyId: '1', address: '1 Example Road' }];
        },
        async getCollections() {
            calls.getCollections += 1;
            return [FOOD];
        },
        async resolveUPRN() {
            calls.resolveUPRN += 1;
            return '6360193';
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

test('validates the postcode before calling upstream', async () => {
    const { provider, calls } = fakeProvider();
    const service = new BinsService({ provider });
    await assert.rejects(service.lookupAddresses('nonsense'), { code: 'INVALID_POSTCODE', status: 400 });
    assert.equal(calls.lookupAddresses, 0);
});

test('caches addresses per normalised postcode for about a week', async () => {
    const clock = manualClock();
    const { provider, calls } = fakeProvider();
    const service = new BinsService({ provider, clock });

    const result = await service.lookupAddresses('br11aa');
    assert.equal(result.postcode, 'BR1 1AA');
    await service.lookupAddresses('BR1  1AA');
    assert.equal(calls.lookupAddresses, 1);

    clock.advance(CACHE_DEFAULTS.addressTtlMs);
    await service.lookupAddresses('BR1 1AA');
    assert.equal(calls.lookupAddresses, 2);
});

test('an empty postcode is NO_ADDRESSES_FOUND, a broken page is UPSTREAM_ERROR', async () => {
    const empty = new BinsService({ provider: fakeProvider({ lookupAddresses: async () => [] }).provider });
    await assert.rejects(empty.lookupAddresses('SW1A 1AA'), { code: 'NO_ADDRESSES_FOUND', status: 404 });

    const broken = new BinsService({
        provider: fakeProvider({ lookupAddresses: async () => { throw new ParserError('ADDRESS_SELECT_MISSING'); } }).provider
    });
    await assert.rejects(broken.lookupAddresses('BR1 1AA'), { code: 'UPSTREAM_ERROR', status: 502 });
});

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

test('resolves and caches UPRNs', async () => {
    const { provider, calls } = fakeProvider();
    const service = new BinsService({ provider });
    assert.deepEqual(await service.resolveUPRN('100020437397'), { uprn: '100020437397', propertyId: '6360193' });
    await service.resolveUPRN('100020437397');
    assert.equal(calls.resolveUPRN, 1);

    const missing = new BinsService({ provider: fakeProvider({ resolveUPRN: async () => null }).provider });
    await assert.rejects(missing.resolveUPRN('1'), { code: 'PROPERTY_NOT_FOUND', status: 404 });
    await assert.rejects(missing.resolveUPRN('x'), { code: 'INVALID_UPRN', status: 400 });
});
