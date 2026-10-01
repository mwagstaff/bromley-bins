import express from 'express';
import { ApiError } from '../errors.js';
import { isNumericId } from '../validation.js';

const INSTALLATION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PUSH_TOKEN = /^[0-9a-f]{32,512}$/i;
const ENVIRONMENTS = new Set(['sandbox', 'production']);
const PHASES = new Set(['eveningBefore', 'collectionDay']);
const SENDS = new Set(['both', 'notification', 'activity']);
const TYPES = new Set(['food', 'recycling', 'paper', 'refuse', 'garden', 'other']);

const invalid = (message) => new ApiError('INVALID_REGISTRATION', 400, message);
const isInt = (value, min, max) => Number.isInteger(value) && value >= min && value <= max;

function optionalToken(value, name) {
    if (value === undefined || value === null) return null;
    if (typeof value !== 'string' || !PUSH_TOKEN.test(value)) throw invalid(`${name} is not a valid push token`);
    return value.toLowerCase();
}

export function parseRegistration(body) {
    if (!body || typeof body !== 'object') throw invalid('Expected a JSON body');
    const { apnsToken, liveActivityToken, environment, propertyId, reminders, hiddenTypes = [] } = body;
    if (!ENVIRONMENTS.has(environment)) throw invalid('environment must be sandbox or production');
    if (!isNumericId(propertyId)) throw invalid('propertyId must be numeric');
    if (!reminders || typeof reminders !== 'object'
        || typeof reminders.enabled !== 'boolean'
        || typeof reminders.showsLiveActivity !== 'boolean'
        || !isInt(reminders.hour, 0, 23)
        || !isInt(reminders.minute, 0, 59)) {
        throw invalid('reminders must have enabled, hour, minute and showsLiveActivity');
    }
    if (!Array.isArray(hiddenTypes) || hiddenTypes.length > 50
        || !hiddenTypes.every((t) => typeof t === 'string' && t.length <= 200)) {
        throw invalid('hiddenTypes must be a list of collection names');
    }
    const registration = {
        apnsToken: optionalToken(apnsToken, 'apnsToken'),
        liveActivityToken: optionalToken(liveActivityToken, 'liveActivityToken'),
        environment,
        propertyId,
        reminders: {
            enabled: reminders.enabled,
            hour: reminders.hour,
            minute: reminders.minute,
            showsLiveActivity: reminders.showsLiveActivity
        },
        hiddenTypes
    };
    if (!registration.apnsToken && !registration.liveActivityToken) {
        throw invalid('At least one push token is required');
    }
    return registration;
}

export function parseTest(body) {
    const { items, phase, delaySeconds = 0, send = 'both' } = body ?? {};
    if (!Array.isArray(items) || items.length < 1 || items.length > 6
        || !items.every((i) => i && typeof i.label === 'string' && i.label.length > 0 && i.label.length <= 100 && TYPES.has(i.type))) {
        throw invalid('items must be 1–6 bins with a label and type');
    }
    if (!PHASES.has(phase)) throw invalid('phase must be eveningBefore or collectionDay');
    if (!isInt(delaySeconds, 0, 600)) throw invalid('delaySeconds must be 0–600');
    if (!SENDS.has(send)) throw invalid('send must be both, notification or activity');
    return { items: items.map(({ label, type }) => ({ label, type })), phase, delaySeconds, send };
}

/**
 *   PUT    /api/devices/:installationId        register or update a device
 *   DELETE /api/devices/:installationId        stop all reminders for it
 *   POST   /api/devices/:installationId/test   debug builds only: send a test now
 */
export function deviceRoutes({ store, scheduler, service, route }) {
    const router = express.Router();
    router.use(express.json({ limit: '16kb' }));

    const installationId = (req) => {
        if (!INSTALLATION_ID.test(req.params.installationId)) {
            throw new ApiError('INVALID_INSTALLATION_ID', 400, 'Invalid installation ID');
        }
        return req.params.installationId.toLowerCase();
    };

    route(router, 'put', '/:installationId', 'registrations', async (req, res) => {
        const id = installationId(req);
        const registration = parseRegistration(req.body);
        try {
            // Rejects made-up property IDs; a council outage shouldn't block registering.
            await service.getCollections(registration.propertyId);
        } catch (error) {
            if (error.code === 'PROPERTY_NOT_FOUND' || error.code === 'INVALID_PROPERTY_ID') throw error;
        }
        await store.upsert(id, registration);
        if (registration.reminders.enabled) scheduler?.tick();
        res.json({ registered: true, remindersEnabled: registration.reminders.enabled });
    });

    route(router, 'delete', '/:installationId', 'registrations', async (req, res) => {
        await store.delete(installationId(req));
        res.status(204).end();
    });

    route(router, 'post', '/:installationId/test', 'tests', async (req, res) => {
        const device = store.get(installationId(req));
        if (!device) throw new ApiError('NOT_REGISTERED', 404, 'Device is not registered');
        // Only development builds register with the sandbox environment.
        if (device.environment !== 'sandbox') throw new ApiError('FORBIDDEN', 403, 'Test reminders are for debug builds');
        if (!scheduler) throw new ApiError('PUSH_DISABLED', 503, 'Push is not configured on this server');
        await scheduler.sendTest(device, parseTest(req.body));
        res.status(202).json({ queued: true });
    });

    return router;
}
