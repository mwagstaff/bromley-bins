import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseAddressResults } from '../lib/bins/address-parser.js';
import { ParserError } from '../lib/errors.js';
import { fixture } from './helpers.js';

const results = fixture('wasteworks-address-results.html');

test('extracts every numeric option with its address text', () => {
    const addresses = parseAddressResults(results);
    assert.equal(addresses.length, 6);
    assert.ok(addresses.every(({ propertyId }) => /^[0-9]+$/.test(propertyId)));
    assert.deepEqual(
        addresses.find(({ propertyId }) => propertyId === '6150011'),
        { propertyId: '6150011', address: 'Ground Floor Shop, 1 Sample Road, Bromley, BR1 1AA' }
    );
});

test('ignores the blank placeholder and the "can\'t find my address" option', () => {
    const addresses = parseAddressResults(results);
    assert.ok(!addresses.some(({ propertyId }) => propertyId === '' || propertyId === 'missing'));
    assert.ok(!addresses.some(({ address }) => /find my address/i.test(address)));
});

test('output does not depend on upstream option order', () => {
    const options = [...results.matchAll(/<option value="[0-9]+">[^<]*<\/option>/g)].map((m) => m[0]);
    const reversed = results.replace(options.join('\n        '), [...options].reverse().join('\n        '));
    assert.notEqual(reversed, results);
    assert.deepEqual(parseAddressResults(reversed), parseAddressResults(results));
    // Natural order: Flat 2 before Flat 10.
    const flats = parseAddressResults(results).map(({ address }) => address.split(',')[0]);
    assert.deepEqual(flats.slice(0, 5), ['Flat 1', 'Flat 2', 'Flat 3', 'Flat 4', 'Flat 10']);
});

test('collapses whitespace and de-duplicates repeated property IDs', () => {
    const html = `<select id="address">
        <option value="">Pick one</option>
        <option value="42">  1   Example
            Road </option>
        <option value="42">1 Example Road</option>
    </select>`;
    assert.deepEqual(parseAddressResults(html), [{ propertyId: '42', address: '1 Example Road' }]);
});

test('a genuine "no results" page is an empty list, not an error', () => {
    assert.deepEqual(parseAddressResults(fixture('wasteworks-address-none.html')), []);
});

test('fails clearly if #address disappears', () => {
    const html = results.replace('id="address"', 'id="property"');
    assert.throws(() => parseAddressResults(html), (error) => error instanceof ParserError && error.reason === 'ADDRESS_SELECT_MISSING');
    assert.throws(() => parseAddressResults('<html><body>Service unavailable</body></html>'), ParserError);
});

test('fails clearly if no numeric property IDs remain', () => {
    const html = results.replace(/value="([0-9]+)"/g, 'value="uprn-$1"');
    assert.throws(() => parseAddressResults(html), (error) => error instanceof ParserError && error.reason === 'NO_NUMERIC_OPTIONS');
});
