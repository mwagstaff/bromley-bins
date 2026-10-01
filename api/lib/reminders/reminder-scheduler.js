import { silentLogger } from '../logger.js';
import { addDays, londonDay, londonInstant } from '../london-time.js';
import { activityKey, planDueReminders } from './reminder-planner.js';

const TOKEN_FIELD = { notification: 'apnsToken', activity: 'liveActivityToken' };

/**
 * Once a minute, works out which reminders are due for each registered device
 * from the latest council calendar and sends them. Because reminders are
 * computed at send time, a schedule change (say, a bank holiday) is picked up
 * automatically, and nothing depends on the app having run recently.
 */
export class ReminderScheduler {
    #timer = null;
    #running = null;

    constructor({ store, service, sender, logger = silentLogger, metrics = null, clock = Date.now, intervalMs = 60_000 }) {
        this.store = store;
        this.service = service;
        this.sender = sender;
        this.logger = logger;
        this.metrics = metrics;
        this.clock = clock;
        this.intervalMs = intervalMs;
    }

    start() {
        this.#timer = setInterval(() => this.tick(), this.intervalMs);
        this.tick();
    }

    stop() {
        clearInterval(this.#timer);
        this.#timer = null;
        return this.#running ?? Promise.resolve();
    }

    /** One pass over every device. Overlapping passes are skipped. */
    tick() {
        if (this.#running) return this.#running;
        this.#running = this.#pass().finally(() => {
            this.#running = null;
        });
        return this.#running;
    }

    async #pass() {
        const nowMs = this.clock();
        for (const device of this.store.all()) {
            if (!device.reminders?.enabled) continue;
            let collections;
            try {
                ({ collections } = await this.service.getCollections(device.propertyId));
            } catch (error) {
                // No schedule (council down with nothing cached): try again next tick.
                this.logger.warn('reminder_schedule_unavailable', { code: error.code });
                continue;
            }
            for (const reminder of planDueReminders({ device, collections, nowMs })) {
                const field = TOKEN_FIELD[reminder.kind];
                if (!device[field]) continue;
                const result = await this.sender.send(device, reminder);
                if (result.dead) {
                    await this.store.removeToken(device.installationId, field);
                } else if (result.ok || !result.retryable) {
                    // Non-retryable rejections are recorded too, so a bad
                    // payload can't be resent every minute.
                    await this.store.markSent(device.installationId, reminder.key);
                }
            }
        }
        this.metrics?.registeredDevices.set(this.store.size);
    }

    /**
     * Debug builds only (the caller checks for the sandbox environment): sends
     * a reminder now or after a short delay with the given bins.
     */
    sendTest(device, { items, phase, delaySeconds, send }) {
        const nowMs = this.clock();
        const today = londonDay(nowMs);
        const day = phase === 'eveningBefore' ? addDays(today, 1) : today;
        const base = {
            day,
            phase,
            items,
            activityKey: `debug.${activityKey(device.propertyId, day, phase)}.${nowMs}`,
            expiresAtMs: nowMs + delaySeconds * 1_000 + 60 * 60 * 1_000,
            staleAtMs: londonInstant(addDays(day, 1))
        };
        const kinds = send === 'both' ? ['notification', 'activity'] : [send];
        const fire = async () => {
            for (const kind of kinds) {
                if (device[TOKEN_FIELD[kind]]) {
                    await this.sender.send(device, { ...base, kind }, { isTest: true });
                }
            }
        };
        if (delaySeconds > 0) {
            setTimeout(fire, delaySeconds * 1_000);
            return Promise.resolve();
        }
        return fire();
    }
}
