import express from 'express';
import { ApiError } from './errors.js';
import { silentLogger } from './logger.js';
import { rateLimit } from './rate-limit.js';
import { deviceRoutes } from './reminders/device-routes.js';

/**
 * Builds the HTTP app around a BinsService and the reminder device store.
 * Routes return normalised JSON only; no upstream HTML, calendar text or URLs
 * ever reach a client.
 */
export function createApp({
    service,
    store = null,
    scheduler = null,
    logger = silentLogger,
    metrics = null,
    rateLimitConfig = { windowMs: 60_000, collections: 60, registrations: 20, tests: 10 },
    trustProxy = 'loopback',
    clock = Date.now
}) {
    const app = express();
    app.disable('x-powered-by');
    app.set('trust proxy', trustProxy);

    app.use((req, res, next) => {
        const startedAt = performance.now();
        res.on('finish', () => {
            const route = res.locals.route ?? 'unmatched';
            metrics?.httpRequests.inc({ route, status: String(res.statusCode) });
            metrics?.httpDuration.observe({ route }, (performance.now() - startedAt) / 1_000);
        });
        next();
    });

    const route = (prefix) => (router, method, path, limitKey, handler) => {
        const label = `${prefix}${path}`;
        router[method](
            path,
            (req, res, next) => {
                res.locals.route = `${method.toUpperCase()} ${label}`;
                next();
            },
            rateLimit({ windowMs: rateLimitConfig.windowMs, max: rateLimitConfig[limitKey], route: label, clock, metrics }),
            handler
        );
    };

    const bins = express.Router();
    route('/api/bins')(bins, 'get', '/:propertyId/collections', 'collections', async (req, res) => {
        const result = await service.getCollections(req.params.propertyId);
        res.set('Cache-Control', result.stale ? 'no-cache' : 'private, max-age=900');
        res.json(result);
    });

    app.use('/api/bins', bins);
    if (store) {
        app.use('/api/devices', deviceRoutes({ store, scheduler, service, route: route('/api/devices') }));
    }

    app.get('/healthcheck', (req, res) => {
        res.locals.route = '/healthcheck';
        res.json({ status: 'ok' });
    });

    if (metrics) {
        app.get('/metrics', async (req, res) => {
            res.locals.route = '/metrics';
            res.set('Content-Type', metrics.registry.contentType);
            res.send(await metrics.registry.metrics());
        });
    }

    app.use((req, res) => {
        res.status(404).json({ error: { code: 'NOT_FOUND', message: 'Not found' } });
    });

    // eslint-disable-next-line no-unused-vars
    app.use((error, req, res, next) => {
        if (error instanceof ApiError) {
            if (error.status >= 500) {
                logger.warn('request_failed', {
                    route: res.locals.route,
                    code: error.code,
                    reason: error.reason,
                    upstreamStatus: error.httpStatus
                });
            }
            res.status(error.status).json({ error: { code: error.code, message: publicMessage(error) } });
            return;
        }
        if (error.type === 'entity.parse.failed' || error.type === 'entity.too.large') {
            res.status(400).json({ error: { code: 'INVALID_BODY', message: 'Request body must be JSON under 16 KB' } });
            return;
        }
        logger.error('unhandled_error', { route: res.locals.route, error });
        res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
    });

    return app;
}

function publicMessage(error) {
    if (error.code === 'UPSTREAM_TIMEOUT') return 'The council service took too long to respond';
    if (error.code === 'UPSTREAM_ERROR') return 'The council service is not responding as expected';
    return error.message;
}
