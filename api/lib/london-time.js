/**
 * Calendar-day and wall-clock helpers for Europe/London.
 *
 * Collection days are `YYYY-MM-DD` strings and reminder times are London wall
 * clock times, so both must be converted with the London offset in force on
 * that day (GMT or BST), never the server's own time zone.
 */
const PARTS = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23'
});

function londonParts(ms) {
    const parts = Object.fromEntries(PARTS.formatToParts(new Date(ms)).map((p) => [p.type, p.value]));
    return {
        year: Number(parts.year),
        month: Number(parts.month),
        day: Number(parts.day),
        hour: Number(parts.hour),
        minute: Number(parts.minute),
        second: Number(parts.second)
    };
}

const pad = (value) => String(value).padStart(2, '0');

/** The London calendar day containing `ms`, as `YYYY-MM-DD`. */
export function londonDay(ms) {
    const { year, month, day } = londonParts(ms);
    return `${year}-${pad(month)}-${pad(day)}`;
}

/** `day` shifted by whole calendar days. */
export function addDays(day, days) {
    const [year, month, date] = day.split('-').map(Number);
    const shifted = new Date(Date.UTC(year, month - 1, date + days));
    return `${shifted.getUTCFullYear()}-${pad(shifted.getUTCMonth() + 1)}-${pad(shifted.getUTCDate())}`;
}

/**
 * The instant when London's clocks read `hour:minute` on `day`.
 * Found by guessing UTC and correcting by the observed offset, twice so the
 * correction itself can cross a GMT/BST change.
 */
export function londonInstant(day, hour = 0, minute = 0) {
    const [year, month, date] = day.split('-').map(Number);
    const target = Date.UTC(year, month - 1, date, hour, minute);
    let guess = target;
    for (let i = 0; i < 2; i += 1) {
        const p = londonParts(guess);
        const shown = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
        guess += target - shown;
    }
    return guess;
}
