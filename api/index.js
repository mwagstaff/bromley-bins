import { createApp } from './lib/app.js';
import { BinsService } from './lib/bins/bins-service.js';
import { WasteWorksProvider } from './lib/bins/wasteworks-provider.js';
import { loadConfig } from './lib/config.js';
import { createLogger } from './lib/logger.js';
import { createMetrics } from './lib/metrics.js';
import { ApnsClient, ApnsTokenSigner } from './lib/push/apns.js';
import { DeviceStore } from './lib/reminders/device-store.js';
import { ReminderScheduler } from './lib/reminders/reminder-scheduler.js';
import { ReminderSender } from './lib/reminders/reminder-sender.js';

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
const service = new BinsService({ provider, metrics });
const store = await new DeviceStore({ dataDir: config.dataDir, logger }).load();

let scheduler = null;
if (config.push.enabled) {
    const signer = config.push.keyPath
        ? ApnsTokenSigner.fromKeyPath({ keyPath: config.push.keyPath, keyId: config.push.keyId, teamId: config.push.teamId })
        : new ApnsTokenSigner({ privateKey: config.push.inlineKey, keyId: config.push.keyId, teamId: config.push.teamId });
    const apns = new ApnsClient({ signer, requestTimeoutMs: config.push.requestTimeoutMs, logger, metrics });
    const sender = new ReminderSender({ apns, bundleId: config.push.bundleId, logger, metrics });
    scheduler = new ReminderScheduler({ store, service, sender, logger, metrics });
    scheduler.start();
} else {
    logger.warn('push_disabled', { reason: 'apns_not_configured' });
}

const app = createApp({
    service,
    store,
    scheduler,
    logger,
    metrics,
    rateLimitConfig: config.rateLimit,
    trustProxy: config.trustProxy
});

const server = app.listen(config.port, config.host, () => {
    logger.info('server_started', {
        port: config.port,
        council: config.council.council,
        version: config.version,
        push: config.push.enabled,
        devices: store.size
    });
});

for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, async () => {
        logger.info('server_stopping', { signal });
        await scheduler?.stop();
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 5_000).unref();
    });
}
