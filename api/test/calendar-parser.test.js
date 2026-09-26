import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseCalendar } from '../lib/bins/calendar-parser.js';
import { collectionLabel, normalizeCollectionType } from '../lib/bins/collection-type.js';
import { ParserError } from '../lib/errors.js';
import { calendar, fixture } from './helpers.js';

test('parses the real WasteWorks calendar fixture', () => {
    const collections = parseCalendar(fixture('wasteworks-calendar.ics'));
    assert.equal(collections.length, 32);
    assert.deepEqual(collections[0], {
        date: '2026-10-02',
        type: 'Food Waste collection',
        label: 'Food Waste',
        normalizedType: 'food'
    });
    // Escaped comma in SUMMARY is unescaped and the raw value is preserved.
    assert.ok(collections.some(({ type }) => type === 'Mixed Recycling (Cans, Plastics & Glass) collection'));
    assert.deepEqual(
        [...new Set(collections.map(({ normalizedType }) => normalizedType))].sort(),
        ['food', 'paper', 'recycling', 'refuse']
    );
    const sorted = [...collections].sort((a, b) => a.date.localeCompare(b.date));
    assert.deepEqual(collections.map(({ date }) => date), sorted.map(({ date }) => date));
});

test('single event', () => {
    assert.deepEqual(parseCalendar(calendar({ start: '20261002', summary: 'Food Waste collection' })), [
        { date: '2026-10-02', type: 'Food Waste collection', label: 'Food Waste', normalizedType: 'food' }
    ]);
});

test('multiple events are sorted ascending by date', () => {
    const result = parseCalendar(calendar(
        { start: '20261016', summary: 'Food Waste collection' },
        { start: '20261002', summary: 'Food Waste collection' },
        { start: '20261009', summary: 'Food Waste collection' }
    ));
    assert.deepEqual(result.map(({ date }) => date), ['2026-10-02', '2026-10-09', '2026-10-16']);
});

test('keeps multiple types on the same day', () => {
    const result = parseCalendar(calendar(
        { start: '20261002', summary: 'Food Waste collection' },
        { start: '20261002', summary: 'Paper & Cardboard collection' },
        { start: '20261002', summary: 'Non-Recyclable Refuse collection' }
    ));
    assert.equal(result.length, 3);
    assert.ok(result.every(({ date }) => date === '2026-10-02'));
});

test('keeps events with unknown or missing types', () => {
    const result = parseCalendar(calendar(
        { start: '20261002', summary: 'Bulky Items collection' },
        { start: '20261003' }
    ));
    assert.deepEqual(result.map(({ normalizedType, type }) => [type, normalizedType]), [
        ['Bulky Items collection', 'other'],
        ['Collection', 'other']
    ]);
});

test('drops only exact date + raw type duplicates', () => {
    const result = parseCalendar(calendar(
        { start: '20261002', summary: 'Food Waste collection' },
        { start: '20261002', summary: 'Food Waste collection' },
        { start: '20261002', summary: 'Food waste collection' },
        { start: '20261009', summary: 'Food Waste collection' }
    ));
    assert.equal(result.length, 3);
});

test('rejects malformed calendars', () => {
    assert.throws(() => parseCalendar('<html>Maintenance</html>'), (error) => error instanceof ParserError && error.reason === 'NOT_VCALENDAR');
    assert.throws(() => parseCalendar(''), ParserError);
    assert.throws(() => parseCalendar('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:2026\r\n'), ParserError);
});

test('an empty calendar parses to no collections', () => {
    assert.deepEqual(parseCalendar(calendar()), []);
});

test('date-only values never shift, whatever the process time zone', () => {
    // 1 Jan and a BST date: both would move a day if converted through UTC in
    // a zone east or west of Greenwich.
    const ics = calendar(
        { start: '20270101', summary: 'Food Waste collection' },
        { start: '20260628', summary: 'Food Waste collection' }
    );
    const originalTz = process.env.TZ;
    try {
        for (const tz of ['Pacific/Kiritimati', 'Pacific/Pago_Pago', 'Europe/London', 'UTC']) {
            process.env.TZ = tz;
            assert.deepEqual(parseCalendar(ics).map(({ date }) => date), ['2026-06-28', '2027-01-01'], tz);
        }
    } finally {
        if (originalTz === undefined) delete process.env.TZ;
        else process.env.TZ = originalTz;
    }
});

test('a UTC timestamp is placed on its Europe/London day', () => {
    const ics = calendar({
        raw: ['BEGIN:VEVENT', 'UID:x', 'DTSTART:20260627T233000Z', 'SUMMARY:Food Waste collection', 'END:VEVENT']
    });
    assert.equal(parseCalendar(ics)[0].date, '2026-06-28');
});

test('normalises Bromley collection names', () => {
    assert.equal(normalizeCollectionType('Food Waste collection'), 'food');
    assert.equal(normalizeCollectionType('Mixed Recycling (Cans, Plastics & Glass) collection'), 'recycling');
    assert.equal(normalizeCollectionType('Paper & Cardboard collection'), 'paper');
    assert.equal(normalizeCollectionType('Non-Recyclable Refuse collection'), 'refuse');
    assert.equal(normalizeCollectionType('Garden Waste collection'), 'garden');
    assert.equal(normalizeCollectionType('Something New'), 'other');
    assert.equal(collectionLabel('Garden Waste collection'), 'Garden Waste');
    assert.equal(collectionLabel('collection'), 'collection');
});
