import { ParserError, UpstreamError } from '../errors.js';
import { silentLogger } from '../logger.js';
import { isNumericId } from '../validation.js';
import { parseCalendar } from './calendar-parser.js';

/**
 * Adapter for SocietyWorks' WasteWorks (FixMyStreet) bin collection sites.
 * Everything specific to WasteWorks' URLs and calendars stays in here; callers
 * only see property IDs and collections.
 *
 * Postcode and address lookup deliberately happen on the phone, so this
 * service never receives a postcode or address.
 *
 * Implements the BinCollectionProvider shape:
 *   getCollections(propertyId) → [{ date, type, label, normalizedType }]
 */
export class WasteWorksProvider {
    constructor({
        council,
        baseUrl,
        userAgent,
        timeoutMs = 10_000,
        fetchImpl = globalThis.fetch,
        logger = silentLogger,
        metrics = null
    }) {
        this.council = council;
        this.name = 'wasteworks';
        this.baseUrl = new URL(baseUrl);
        this.userAgent = userAgent;
        this.timeoutMs = timeoutMs;
        this.fetch = fetchImpl;
        this.logger = logger;
        this.metrics = metrics;
    }

    async getCollections(propertyId) {
        if (!isNumericId(propertyId)) throw new TypeError('propertyId must be numeric');
        return this.#request('get_collections', `/waste/${propertyId}/calendar.ics`, {
            headers: { Accept: 'text/calendar,text/plain' }
        }, async (response) => parseCalendar(await response.text()));
    }

    async #request(operation, path, init, handle) {
        const startedAt = performance.now();
        let httpStatus;
        let outcome = 'ok';
        let failureReason;
        try {
            let response;
            try {
                response = await this.fetch(new URL(path, this.baseUrl), {
                    ...init,
                    headers: { 'User-Agent': this.userAgent, ...init.headers },
                    signal: AbortSignal.timeout(this.timeoutMs)
                });
            } catch (error) {
                const timeout = error?.name === 'TimeoutError' || error?.name === 'AbortError';
                throw new UpstreamError(timeout ? 'TIMEOUT' : 'NETWORK', {
                    timeout,
                    message: error?.message
                });
            }

            httpStatus = response.status;
            if (!response.ok) {
                await response.body?.cancel();
                throw new UpstreamError('HTTP_STATUS', { httpStatus: response.status });
            }
            return await handle(response);
        } catch (error) {
            outcome = error instanceof ParserError ? 'parse_error' : 'error';
            if (!(error instanceof UpstreamError)) throw error;
            error.httpStatus ??= httpStatus;
            failureReason = error.reason;
            this.metrics?.upstreamFailures.inc({
                council: this.council,
                operation,
                reason: error.reason
            });
            throw error;
        } finally {
            const durationSeconds = (performance.now() - startedAt) / 1_000;
            this.metrics?.upstreamDuration.observe({
                council: this.council,
                operation,
                outcome
            }, durationSeconds);
            // Deliberately no postcode, address or property ID in the log line.
            const log = outcome === 'ok' ? this.logger.info : this.logger.warn;
            log('upstream_request', {
                provider: this.name,
                council: this.council,
                operation,
                httpStatus,
                outcome,
                failureReason,
                durationMs: Math.round(durationSeconds * 1_000)
            });
        }
    }
}
