import ICAL from 'ical.js';
import { ParserError } from '../errors.js';
import { collectionLabel, normalizeCollectionType } from './collection-type.js';

const LONDON_DATE = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Europe/London',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
});

const pad = (value, length = 2) => String(value).padStart(length, '0');

/**
 * Collection dates are calendar days, not instants. For all-day (VALUE=DATE)
 * events we read the Y/M/D fields directly so nothing is ever shifted through
 * UTC. Should an event ever carry a UTC timestamp instead, it is placed on its
 * Europe/London day.
 */
function toCollectionDate(time) {
    if (time.isDate || !time.zone || time.zone.tzid !== 'UTC') {
        return `${pad(time.year, 4)}-${pad(time.month)}-${pad(time.day)}`;
    }
    return LONDON_DATE.format(time.toJSDate());
}

/**
 * Parses a WasteWorks bin calendar into collections sorted by date.
 * Every event with a start date is kept, whatever its summary says; only exact
 * date + raw type duplicates are dropped.
 */
export function parseCalendar(text) {
    if (typeof text !== 'string' || !/^\s*BEGIN:VCALENDAR/i.test(text)) {
        throw new ParserError('NOT_VCALENDAR', 'Response is not an iCalendar document');
    }

    let calendar;
    try {
        calendar = new ICAL.Component(ICAL.parse(text));
    } catch (error) {
        throw new ParserError('ICS_PARSE_FAILED', `Calendar could not be parsed: ${error.message}`);
    }
    if (calendar.name !== 'vcalendar') {
        throw new ParserError('NOT_VCALENDAR', 'Top-level component is not VCALENDAR');
    }

    const seen = new Set();
    const collections = [];
    for (const event of calendar.getAllSubcomponents('vevent')) {
        const start = event.getFirstPropertyValue('dtstart');
        if (!(start instanceof ICAL.Time)) continue;

        const date = toCollectionDate(start);
        const type = String(event.getFirstPropertyValue('summary') ?? '').trim() || 'Collection';
        const key = `${date}|${type}`;
        if (seen.has(key)) continue;
        seen.add(key);

        collections.push({
            date,
            type,
            label: collectionLabel(type),
            normalizedType: normalizeCollectionType(type)
        });
    }

    return collections.sort((a, b) => a.date.localeCompare(b.date) || a.type.localeCompare(b.type));
}
