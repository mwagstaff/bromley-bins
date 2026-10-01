import assert from 'node:assert/strict';
import { mkdtemp } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { addDays, londonDay, londonInstant } from '../lib/london-time.js';
import { DeviceStore } from '../lib/reminders/device-store.js';
import { planDueReminders, reminderBody } from '../lib/reminders/reminder-planner.js';
import { ReminderScheduler } from '../lib/reminders/reminder-scheduler.js';
import { ReminderSender } from '../lib/reminders/reminder-sender.js';
import { manualClock } from './helpers.js';

const at = (iso) => Date.parse(iso);

const collection = (date, label, normalizedType) => ({ date, type: `${label} collection`, label, normalizedType });
const SCHEDULE = [
    collection('2026-10-02', 'Mixed Recycling', 'recycling'),
    collection('2026-10-02', 'Food Waste', 'food'),
    collection('2026-10-09', 'Food Waste', 'food'),
    collection('2026-10-09', 'Paper & Cardboard', 'paper')
];

function device(overrides = {}) {
    return {
        installationId: 'device-1',
        apnsToken: 'a'.repeat(64),
        liveActivityToken: 'b'.repeat(64),
        environment: 'production',
        propertyId: '3642936',
        reminders: { enabled: true, hour: 19, minute: 0, showsLiveActivity: true },
        hiddenTypes: [],
        sent: {},
        ...overrides
    };
}

test('London day and wall-clock conversion across GMT and BST', () => {
    assert.equal(londonDay(at('2026-06-27T23:30:00Z')), '2026-06-28'); // BST
    assert.equal(londonDay(at('2026-12-31T23:50:00Z')), '2026-12-31'); // GMT
    assert.equal(new Date(londonInstant('2026-10-01', 19)).toISOString(), '2026-10-01T18:00:00.000Z');
    assert.equal(new Date(londonInstant('2026-11-01', 19)).toISOString(), '2026-11-01T19:00:00.000Z');
    // Clocks go back at 02:00 BST on 25 Oct 2026; midnight that day is still BST.
    assert.equal(new Date(londonInstant('2026-10-25')).toISOString(), '2026-10-24T23:00:00.000Z');
    assert.equal(new Date(londonInstant('2026-10-26')).toISOString(), '2026-10-26T00:00:00.000Z');
    assert.equal(addDays('2026-12-31', 1), '2027-01-01');
    assert.equal(addDays('2026-03-01', -1), '2026-02-28');
});

test('reminder wording matches the app', () => {
    assert.equal(reminderBody(['Food Waste']), 'Food Waste is being collected tomorrow.');
    assert.equal(reminderBody(['A', 'B', 'C']), 'A, B and C are being collected tomorrow.');
});

test('nothing is due before the reminder time', () => {
    assert.deepEqual(planDueReminders({ device: device(), collections: SCHEDULE, nowMs: at('2026-10-01T17:59:00Z') }), []);
});

test('the evening before: a notification and a Live Activity, until midnight', () => {
    const due = planDueReminders({ device: device(), collections: SCHEDULE, nowMs: at('2026-10-01T18:00:00Z') });
    assert.deepEqual(due.map((r) => [r.kind, r.phase, r.day]), [
        ['notification', 'eveningBefore', '2026-10-02'],
        ['activity', 'eveningBefore', '2026-10-02']
    ]);
    assert.deepEqual(due[0].items, [{ label: 'Food Waste', type: 'food' }, { label: 'Mixed Recycling', type: 'recycling' }]);
    assert.equal(due[1].activityKey, '3642936.2026-10-02.eveningBefore');
    assert.equal(new Date(due[0].expiresAtMs).toISOString(), '2026-10-01T23:00:00.000Z');
    assert.equal(new Date(due[1].staleAtMs).toISOString(), '2026-10-02T23:00:00.000Z');

    // Still due late in the evening (e.g. after downtime), not after midnight.
    assert.equal(planDueReminders({ device: device(), collections: SCHEDULE, nowMs: at('2026-10-01T22:59:00Z') }).length, 2);
    assert.equal(planDueReminders({ device: device(), collections: SCHEDULE, nowMs: at('2026-10-01T23:01:00Z') }).length, 0);
});

test('collection day: a fresh Live Activity from 07:00 until 18:00', () => {
    assert.deepEqual(planDueReminders({ device: device(), collections: SCHEDULE, nowMs: at('2026-10-02T05:59:00Z') }), []);
    const due = planDueReminders({ device: device(), collections: SCHEDULE, nowMs: at('2026-10-02T06:00:00Z') });
    assert.deepEqual(due.map((r) => [r.kind, r.phase]), [['activity', 'collectionDay']]);
    assert.deepEqual(planDueReminders({ device: device(), collections: SCHEDULE, nowMs: at('2026-10-02T17:00:00Z') }), []);
});

test('already-sent reminders, hidden bins and settings are respected', () => {
    const now = at('2026-10-01T19:00:00Z');
    const sent = { '2026-10-02|eveningBefore|notification': '2026-10-01T18:00:05Z' };
    assert.deepEqual(planDueReminders({ device: device({ sent }), collections: SCHEDULE, nowMs: now }).map((r) => r.kind), ['activity']);

    const hidden = device({ hiddenTypes: ['Food Waste collection', 'Mixed Recycling collection'] });
    assert.deepEqual(planDueReminders({ device: hidden, collections: SCHEDULE, nowMs: now }), []);

    const noActivity = device({ reminders: { enabled: true, hour: 19, minute: 0, showsLiveActivity: false } });
    assert.deepEqual(planDueReminders({ device: noActivity, collections: SCHEDULE, nowMs: now }).map((r) => r.kind), ['notification']);

    assert.deepEqual(planDueReminders({ device: device({ liveActivityToken: null }), collections: SCHEDULE, nowMs: now }).map((r) => r.kind), ['notification']);

    const off = device({ reminders: { enabled: false, hour: 19, minute: 0, showsLiveActivity: true } });
    assert.deepEqual(planDueReminders({ device: off, collections: SCHEDULE, nowMs: now }), []);

    const early = device({ reminders: { enabled: true, hour: 17, minute: 30, showsLiveActivity: false } });
    assert.equal(planDueReminders({ device: early, collections: SCHEDULE, nowMs: at('2026-10-01T16:30:00Z') }).length, 1);
});

test('notification and Live Activity payloads', async () => {
    const requests = [];
    const apns = { send: async (request) => { requests.push(request); return { ok: true, status: 200 }; } };
    const sender = new ReminderSender({ apns, bundleId: 'dev.skynolimit.bromleybins', clock: () => at('2026-10-01T18:00:00Z') });
    const [notification, activity] = planDueReminders({ device: device(), collections: SCHEDULE, nowMs: at('2026-10-01T18:00:00Z') });

    await sender.send(device(), notification);
    await sender.send(device(), activity);

    assert.deepEqual(requests[0], {
        token: 'a'.repeat(64),
        topic: 'dev.skynolimit.bromleybins',
        pushType: 'alert',
        priority: 10,
        expiration: at('2026-10-01T23:00:00Z') / 1_000,
        collapseId: 'reminder-2026-10-02',
        environment: 'production',
        payload: {
            aps: {
                alert: { title: 'Bins out tonight', body: 'Food Waste and Mixed Recycling are being collected tomorrow.' },
                sound: 'default',
                'thread-id': 'bins'
            }
        }
    });

    const { aps } = requests[1].payload;
    assert.equal(requests[1].token, 'b'.repeat(64));
    assert.equal(requests[1].topic, 'dev.skynolimit.bromleybins.push-type.liveactivity');
    assert.equal(requests[1].pushType, 'liveactivity');
    assert.equal(aps.event, 'start');
    assert.equal(aps['attributes-type'], 'BinDayActivityAttributes');
    assert.deepEqual(aps.attributes, { key: '3642936.2026-10-02.eveningBefore', day: '2026-10-02', phase: 'eveningBefore', isTest: false });
    assert.deepEqual(aps['content-state'], { items: notification.items });
    assert.equal(aps.timestamp, at('2026-10-01T18:00:00Z') / 1_000);
    assert.equal(aps['stale-date'], at('2026-10-02T23:00:00Z') / 1_000);
    assert.equal(aps.alert.sound, 'silence.caf');
});

async function harness({ results = () => ({ ok: true, status: 200 }), collections = SCHEDULE } = {}) {
    const clock = manualClock(at('2026-10-01T18:00:30Z'));
    const store = await new DeviceStore({ dataDir: await mkdtemp(path.join(os.tmpdir(), 'bins-sched-')), clock }).load();
    const sends = [];
    const sender = { send: async (dev, reminder) => { sends.push(reminder); return results(reminder); } };
    const service = {
        getCollections: async () => {
            if (collections instanceof Error) throw collections;
            return { collections };
        }
    };
    const scheduler = new ReminderScheduler({ store, service, sender, clock });
    return { clock, store, sends, scheduler };
}

test('scheduler sends each reminder once and survives restarts', async () => {
    const { store, sends, scheduler, clock } = await harness();
    await store.upsert('device-1', device());
    await scheduler.tick();
    await scheduler.tick();
    assert.deepEqual(sends.map((r) => r.kind), ['notification', 'activity']);

    const reloaded = await new DeviceStore({ dataDir: path.dirname(store.file), clock }).load();
    assert.deepEqual(Object.keys(reloaded.get('device-1').sent).sort(), [
        '2026-10-02|eveningBefore|activity',
        '2026-10-02|eveningBefore|notification'
    ]);

    clock.advance(12 * 60 * 60 * 1_000); // 06:00 UTC = 07:00 BST on bin day
    await scheduler.tick();
    assert.deepEqual(sends.map((r) => r.phase), ['eveningBefore', 'eveningBefore', 'collectionDay']);
});

test('scheduler retries transient failures and drops dead tokens', async () => {
    let attempt = 0;
    const { store, sends, scheduler } = await harness({
        results: (reminder) => {
            if (reminder.kind === 'activity') return { ok: false, dead: true, status: 410, reason: 'Unregistered' };
            attempt += 1;
            return attempt === 1 ? { ok: false, retryable: true, status: 503 } : { ok: true, status: 200 };
        }
    });
    await store.upsert('device-1', device());
    await scheduler.tick();
    assert.equal(store.get('device-1').liveActivityToken, null);
    await scheduler.tick();
    assert.deepEqual(sends.map((r) => r.kind), ['notification', 'activity', 'notification']);
    assert.ok(store.get('device-1').sent['2026-10-02|eveningBefore|notification']);
});

test('scheduler skips devices whose schedule is unavailable', async () => {
    const { store, sends, scheduler } = await harness({ collections: Object.assign(new Error('down'), { code: 'UPSTREAM_ERROR' }) });
    await store.upsert('device-1', device());
    await scheduler.tick();
    assert.deepEqual(sends, []);
});

test('changing property clears sent history', async () => {
    const { store } = await harness();
    await store.upsert('device-1', device());
    await store.markSent('device-1', 'x');
    await store.upsert('device-1', device());
    assert.ok(store.get('device-1').sent.x);
    await store.upsert('device-1', device({ propertyId: '1' }));
    assert.deepEqual(store.get('device-1').sent, {});
});

test('test reminders use test keys and only the requested kinds', async () => {
    const { scheduler, sends } = await harness();
    await scheduler.sendTest(device(), {
        items: [{ label: 'Garden Waste', type: 'garden' }],
        phase: 'collectionDay',
        delaySeconds: 0,
        send: 'activity'
    });
    assert.equal(sends.length, 1);
    assert.equal(sends[0].kind, 'activity');
    assert.equal(sends[0].day, '2026-10-01');
    assert.match(sends[0].activityKey, /^debug\./);
});
