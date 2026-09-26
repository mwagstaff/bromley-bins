import { createApp } from './lib/app.js';
import { BinsService } from './lib/bins/bins-service.js';
import { WasteWorksProvider } from './lib/bins/wasteworks-provider.js';
import { loadConfig } from './lib/config.js';
import { createLogger } from './lib/logger.js';
import { createMetrics } from './lib/metrics.js';

const config = loadConfig();
const logger = createLogger();
const metrics = createMetrics();

const provider = new WasteWorksProvider({
    council: config.council.council,
    baseUrl: config.council.baseUrl,
    userAgent: config.userAgent,
    timeoutMs: config.upstreamTimeoutMs,
    logger,
    metrics
});

const app = createApp({
    service: new BinsService({ provider, metrics }),
    logger,
    metrics,
    rateLimitConfig: config.rateLimit,
    trustProxy: config.trustProxy
});

const server = app.listen(config.port, config.host, () => {
    logger.info('server_started', {
        port: config.port,
        council: config.council.council,
        version: config.version
    });
});

for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => {
        logger.info('server_stopping', { signal });
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 5_000).unref();
    });
}
