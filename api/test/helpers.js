import { readFileSync } from 'node:fs';

export function fixture(name) {
    return readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
}

/** Wraps event lines in a minimal VCALENDAR. */
export function calendar(...events) {
    return [
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        'PRODID://Test//EN',
        ...events.flatMap(({ start, summary, raw }) => raw ?? [
            'BEGIN:VEVENT',
            `UID:${start}-${summary}@test`,
            `DTSTART;VALUE=DATE:${start}`,
            ...(summary === undefined ? [] : [`SUMMARY:${summary}`]),
            'END:VEVENT'
        ]),
        'END:VCALENDAR',
        ''
    ].join('\r\n');
}

/**
 * A fetch stand-in: `routes` maps "METHOD path" to a handler returning a
 * Response (or throwing). Records every call.
 */
export function fakeFetch(routes) {
    const calls = [];
    const fetchImpl = async (url, init = {}) => {
        const method = init.method ?? 'GET';
        const key = `${method} ${new URL(url).pathname}`;
        calls.push({ key, url: String(url), init });
        const handler = routes[key];
        if (!handler) return new Response('not found', { status: 404 });
        return handler(init, calls.length);
    };
    fetchImpl.calls = calls;
    return fetchImpl;
}

export function manualClock(start = Date.parse('2026-09-27T12:00:00Z')) {
    let now = start;
    const clock = () => now;
    clock.advance = (ms) => { now += ms; };
    return clock;
}
