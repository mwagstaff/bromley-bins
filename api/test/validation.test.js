import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isNumericId, normalizePostcode } from '../lib/validation.js';

test('normalises postcode spacing and casing', () => {
    for (const input of ['BR31AA', 'br31aa', 'BR3 1AA', 'BR3   1AA', ' br3 1aa ', 'Br3\t1Aa']) {
        assert.equal(normalizePostcode(input), 'BR3 1AA', input);
    }
    assert.equal(normalizePostcode('se96ab'), 'SE9 6AB');
    assert.equal(normalizePostcode('SW1A1AA'), 'SW1A 1AA');
    assert.equal(normalizePostcode('tn163aa'), 'TN16 3AA');
});

test('rejects things that cannot be postcodes', () => {
    for (const input of ['', 'BR3', '12345', 'BR3 1AAA', 'BR3-1AA', '<script>', 'BR3 1A', undefined, null, ['BR3 1AA']]) {
        assert.equal(normalizePostcode(input), null, String(input));
    }
});

test('accepts only positive numeric IDs', () => {
    assert.equal(isNumericId('3642936'), true);
    for (const input of ['', '0', '000', '12a', '-1', '1.5', ' 12', '1234567890123456', undefined, 12]) {
        assert.equal(isNumericId(input), false, String(input));
    }
});
