import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { silentLogger } from '../logger.js';

const SENT_RETENTION_MS = 4 * 24 * 60 * 60 * 1_000;

/**
 * Devices registered for reminder pushes, persisted as one JSON file.
 *
 * A record holds only what reminders need: APNs tokens, the council property
 * ID, reminder settings, hidden bin types and which reminders were sent. The
 * app never sends a postcode or address.
 */
export class DeviceStore {
    #devices = new Map();
    #writing = Promise.resolve();

    constructor({ dataDir, logger = silentLogger, clock = Date.now }) {
        this.file = path.join(dataDir, 'devices.json');
        this.logger = logger;
        this.clock = clock;
    }

    async load() {
        try {
            const records = JSON.parse(await readFile(this.file, 'utf8'));
            for (const record of records) this.#devices.set(record.installationId, record);
        } catch (error) {
            if (error.code !== 'ENOENT') {
                this.logger.error('device_store_load_failed', { error });
                throw error;
            }
        }
        this.logger.info('device_store_loaded', { devices: this.#devices.size });
        return this;
    }

    get size() {
        return this.#devices.size;
    }

    get(installationId) {
        return this.#devices.get(installationId);
    }

    all() {
        return [...this.#devices.values()];
    }

    /** Creates or replaces a registration, keeping its sent history. */
    async upsert(installationId, registration) {
        const existing = this.#devices.get(installationId);
        const now = new Date(this.clock()).toISOString();
        // A different property or tokens means earlier sends no longer apply.
        const keepSent = existing && existing.propertyId === registration.propertyId;
        this.#devices.set(installationId, {
            ...registration,
            installationId,
            sent: keepSent ? existing.sent : {},
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        });
        await this.#persist();
        return this.#devices.get(installationId);
    }

    async delete(installationId) {
        const existed = this.#devices.delete(installationId);
        if (existed) await this.#persist();
        return existed;
    }

    async markSent(installationId, key) {
        const device = this.#devices.get(installationId);
        if (!device) return;
        const nowMs = this.clock();
        const sent = Object.fromEntries(
            Object.entries(device.sent ?? {}).filter(([, at]) => nowMs - Date.parse(at) < SENT_RETENTION_MS)
        );
        sent[key] = new Date(nowMs).toISOString();
        device.sent = sent;
        await this.#persist();
    }

    /** Drops a token APNs reported as dead; drops the device if nothing is left. */
    async removeToken(installationId, field) {
        const device = this.#devices.get(installationId);
        if (!device) return;
        device[field] = null;
        if (!device.apnsToken && !device.liveActivityToken) {
            this.#devices.delete(installationId);
        }
        await this.#persist();
    }

    #persist() {
        const snapshot = JSON.stringify(this.all(), null, 2);
        this.#writing = this.#writing
            .catch(() => {})
            .then(async () => {
                await mkdir(path.dirname(this.file), { recursive: true });
                const temp = `${this.file}.${process.pid}.tmp`;
                await writeFile(temp, snapshot, { mode: 0o600 });
                await rename(temp, this.file);
            });
        return this.#writing;
    }
}
