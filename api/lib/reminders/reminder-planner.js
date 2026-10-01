import { addDays, londonDay, londonInstant } from '../london-time.js';

/**
 * iOS removes a Live Activity at most 12 hours after it starts (8 active plus
 * 4 on the Lock Screen). The bin-day card starts then, so the two never show
 * together: 07:00 for the default 19:00 reminder. Must match the app's
 * `BinDayActivityPlanner.maximumLifetime`.
 */
export const MAXIMUM_LIFETIME_MS = 12 * 60 * 60 * 1_000;
/** After this hour on bin day a "Bin day today" activity is no longer useful. */
const MORNING_CUTOFF_HOUR = 18;

/** When the bin-day card takes over: 12 hours after the evening one, never before the day. */
export function collectionDayStartMs(eveningStartMs, day) {
    return Math.max(eveningStartMs + MAXIMUM_LIFETIME_MS, londonInstant(day));
}

/**
 * The evening card goes stale at the start of collection day, when the app
 * shows it as a bin-day card; the bin-day card goes stale when the day ends.
 * Must match `BinDayPhase.staleDate(for:)` in the app.
 */
export function staleAtMs(day, phase) {
    return londonInstant(phase === 'eveningBefore' ? day : addDays(day, 1));
}

const listFormat = new Intl.ListFormat('en-GB', { style: 'long', type: 'conjunction' });

export function reminderTitle() {
    return 'Bins out tonight';
}

export function reminderBody(labels) {
    return `${listFormat.format(labels)} ${labels.length === 1 ? 'is' : 'are'} being collected tomorrow.`;
}

export function phaseHeadline(phase) {
    return phase === 'eveningBefore' ? 'Bins out tonight' : 'Bin day today';
}

/** Must match `BinDayActivityPlanner.key` in the app. */
export function activityKey(propertyId, day, phase) {
    return `${propertyId}.${day}.${phase}`;
}

const TYPE_ORDER = ['food', 'recycling', 'paper', 'refuse', 'garden', 'other'];

/** Visible collections on `day`, in the app's display order. */
function itemsOn(collections, day, hiddenTypes) {
    const hidden = new Set(hiddenTypes);
    return collections
        .filter((c) => c.date === day && !hidden.has(c.type))
        .sort((a, b) => TYPE_ORDER.indexOf(a.normalizedType) - TYPE_ORDER.indexOf(b.normalizedType)
            || a.label.localeCompare(b.label))
        .map((c) => ({ label: c.label, type: TYPE_ORDER.includes(c.normalizedType) ? c.normalizedType : 'other' }));
}

/**
 * The pushes that are due for one device right now and haven't been sent.
 *
 * - The evening before a collection, from the reminder time until midnight:
 *   a reminder notification and (if wanted) a "Bins out tonight" Live Activity.
 * - On collection day, from 12 hours after the reminder time (07:00 by
 *   default) until 18:00: a "Bin day today" Live Activity, as iOS has removed
 *   the evening one by then.
 *
 * Windows rather than exact times mean a send missed while the server was down
 * or the council was unreachable still goes out once possible, and a device
 * registered mid-window gets that evening's reminder.
 */
export function planDueReminders({ device, collections, nowMs }) {
    const { reminders, propertyId } = device;
    if (!reminders?.enabled) return [];

    const sent = new Set(Object.keys(device.sent ?? {}));
    const today = londonDay(nowMs);
    const tomorrow = addDays(today, 1);
    const due = [];

    const tomorrowItems = itemsOn(collections, tomorrow, device.hiddenTypes ?? []);
    if (tomorrowItems.length > 0) {
        const start = londonInstant(today, reminders.hour, reminders.minute);
        const end = londonInstant(tomorrow);
        if (nowMs >= start && nowMs < end) {
            due.push({ kind: 'notification', day: tomorrow, phase: 'eveningBefore', items: tomorrowItems, expiresAtMs: end });
            if (reminders.showsLiveActivity && device.liveActivityToken) {
                due.push({ kind: 'activity', day: tomorrow, phase: 'eveningBefore', items: tomorrowItems, expiresAtMs: end });
            }
        }
    }

    const todayItems = itemsOn(collections, today, device.hiddenTypes ?? []);
    if (todayItems.length > 0 && reminders.showsLiveActivity && device.liveActivityToken) {
        const eveningStart = londonInstant(addDays(today, -1), reminders.hour, reminders.minute);
        const start = collectionDayStartMs(eveningStart, today);
        const end = londonInstant(today, MORNING_CUTOFF_HOUR);
        if (nowMs >= start && nowMs < end) {
            due.push({ kind: 'activity', day: today, phase: 'collectionDay', items: todayItems, expiresAtMs: end });
        }
    }

    return due
        .map((reminder) => ({
            ...reminder,
            key: `${reminder.day}|${reminder.phase}|${reminder.kind}`,
            activityKey: activityKey(propertyId, reminder.day, reminder.phase),
            staleAtMs: staleAtMs(reminder.day, reminder.phase)
        }))
        .filter((reminder) => !sent.has(reminder.key));
}
