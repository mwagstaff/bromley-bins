import { silentLogger } from '../logger.js';
import { phaseHeadline, reminderBody, reminderTitle } from './reminder-planner.js';

const listFormat = new Intl.ListFormat('en-GB', { style: 'long', type: 'conjunction' });

/**
 * Turns planned reminders into APNs requests: an alert notification, or a
 * push-to-start for the app's `BinDayActivityAttributes` Live Activity.
 */
export class ReminderSender {
    constructor({ apns, bundleId, logger = silentLogger, metrics = null, clock = Date.now }) {
        this.apns = apns;
        this.bundleId = bundleId;
        this.logger = logger;
        this.metrics = metrics;
        this.clock = clock;
    }

    /** Resolves `{ ok, dead, retryable, status, reason }`. */
    async send(device, reminder, { isTest = false } = {}) {
        const request = reminder.kind === 'notification'
            ? this.#notification(device, reminder)
            : this.#liveActivityStart(device, reminder, isTest);
        let result;
        try {
            result = await this.apns.send({ ...request, environment: device.environment });
        } catch (error) {
            result = { ok: false, retryable: true, dead: false, status: null, reason: error.message };
        }
        this.metrics?.pushes.inc({
            kind: reminder.kind,
            outcome: result.ok ? 'sent' : result.dead ? 'dead_token' : 'failed'
        });
        const log = result.ok ? this.logger.info : this.logger.warn;
        log('reminder_push', {
            kind: reminder.kind,
            phase: reminder.phase,
            test: isTest,
            status: result.status,
            reason: result.reason
        });
        return result;
    }

    #notification(device, reminder) {
        const expiration = Math.floor(reminder.expiresAtMs / 1_000);
        return {
            token: device.apnsToken,
            topic: this.bundleId,
            pushType: 'alert',
            priority: 10,
            expiration,
            collapseId: `reminder-${reminder.day}`,
            payload: {
                aps: {
                    alert: { title: reminderTitle(), body: reminderBody(reminder.items.map((i) => i.label)) },
                    sound: 'default',
                    'thread-id': 'bins'
                }
            }
        };
    }

    #liveActivityStart(device, reminder, isTest) {
        return {
            token: device.liveActivityToken,
            topic: `${this.bundleId}.push-type.liveactivity`,
            pushType: 'liveactivity',
            priority: 10,
            expiration: Math.floor(reminder.expiresAtMs / 1_000),
            payload: {
                aps: {
                    timestamp: Math.floor(this.clock() / 1_000),
                    event: 'start',
                    'attributes-type': 'BinDayActivityAttributes',
                    attributes: {
                        key: reminder.activityKey,
                        day: reminder.day,
                        phase: reminder.phase,
                        isTest
                    },
                    'content-state': { items: reminder.items },
                    'stale-date': Math.floor(reminder.staleAtMs / 1_000),
                    'relevance-score': 100,
                    // Silent: the reminder notification is the one that makes a sound.
                    alert: {
                        title: phaseHeadline(reminder.phase),
                        body: listFormat.format(reminder.items.map((i) => i.label)),
                        sound: 'silence.caf'
                    }
                }
            }
        };
    }
}
