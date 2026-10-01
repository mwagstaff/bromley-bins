import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isNumericId } from '../lib/validation.js';

test('accepts only positive numeric IDs', () => {
    assert.equal(isNumericId('3642936'), true);
    for (const input of ['', '0', '000', '12a', '-1', '1.5', ' 12', '1234567890123456', undefined, 12]) {
        assert.equal(isNumericId(input), false, String(input));
    }
});
