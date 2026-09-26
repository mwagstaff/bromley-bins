import { ParserError, UpstreamError } from '../errors.js';
import { silentLogger } from '../logger.js';
import { isNumericId } from '../validation.js';
import { parseAddressResults } from './address-parser.js';
import { parseCalendar } from './calendar-parser.js';

const PROPERTY_PATH = /^\/waste\/([0-9]+)\/?$/;

/**
 * Adapter for SocietyWorks' WasteWorks (FixMyStreet) bin collection sites.
 * Everything specific to WasteWorks' URLs, HTML and calendars stays in here;
 * callers only see addresses, property IDs and collections.
 *
 * Implements the BinCollectionProvider shape:
 *   lookupAddresses(postcode) → [{ propertyId, address }]
 *   getCollections(propertyId) → [{ date, type, label, normalizedType }]
 *   resolveUPRN(uprn) → propertyId | null
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

    /** `postcode` must already be normalised. */
    async lookupAddresses(postcode) {
        return this.#request('lookup_addresses', '/waste', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                Accept: 'text/html'
            },
            body: new URLSearchParams({ postcode }).toString()
        }, async (response) => parseAddressResults(await response.text()));
    }

    async getCollections(propertyId) {
        if (!isNumericId(propertyId)) throw new TypeError('propertyId must be numeric');
        return this.#request('get_collections', `/waste/${propertyId}/calendar.ics`, {
            headers: { Accept: 'text/calendar,text/plain' }
        }, async (response) => parseCalendar(await response.text()));
    }

    async resolveUPRN(uprn) {
        if (!isNumericId(uprn)) throw new TypeError('uprn must be numeric');
        return this.#request('resolve_uprn', `/property/${uprn}`, {
            headers: { Accept: 'text/html' },
            redirect: 'manual'
        }, async (response) => {
            await response.body?.cancel();
            if (response.status < 300 || response.status >= 400) return null;
            const location = response.headers.get('location');
            if (!location) throw new ParserError('REDIRECT_WITHOUT_LOCATION');
            const match = new URL(location, this.baseUrl).pathname.match(PROPERTY_PATH);
            if (!match) throw new ParserError('UNEXPECTED_REDIRECT', 'UPRN redirect was not to a property page');
            return match[1];
        }, { acceptStatus: (status) => (status >= 200 && status < 400) || status === 404 });
    }

    async #request(operation, path, init, handle, { acceptStatus } = {}) {
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
            const accepted = acceptStatus ? acceptStatus(response.status) : response.ok;
            if (!accepted) {
                await response.body?.cancel();
                throw new UpstreamError('HTTP_STATUS', { httpStatus: response.status });
            }
            if (response.status === 404) {
                await response.body?.cancel();
                return null;
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
