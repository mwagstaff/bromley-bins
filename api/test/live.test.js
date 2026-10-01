import assert from 'node:assert/strict';
import { test } from 'node:test';
import { WasteWorksProvider } from '../lib/bins/wasteworks-provider.js';
import { COUNCILS } from '../lib/config.js';

// Opt-in smoke test against the real Bromley WasteWorks service:
//   npm run test:live
const live = process.env.LIVE_TESTS === '1';

const provider = new WasteWorksProvider({
    ...COUNCILS.bromley,
    userAgent: 'BromleyBins/live-test (+https://skynolimit.dev)'
});

test('live: property 3642936 calendar parses', { skip: !live && 'set LIVE_TESTS=1' }, async () => {
    const collections = await provider.getCollections('3642936');
    assert.ok(collections.length > 0, 'expected upcoming collections');
    for (const { date, type, normalizedType } of collections) {
        assert.match(date, /^\d{4}-\d{2}-\d{2}$/);
        assert.ok(type.length > 0);
        assert.ok(normalizedType);
    }
});
