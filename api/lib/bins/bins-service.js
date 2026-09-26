import { StaleWhileErrorCache } from '../cache.js';
import { ApiError, UpstreamError } from '../errors.js';
import { isNumericId, normalizePostcode } from '../validation.js';

const HOUR_MS = 60 * 60 * 1_000;
const DAY_MS = 24 * HOUR_MS;

export const CACHE_DEFAULTS = Object.freeze({
    addressTtlMs: 7 * DAY_MS,
    collectionTtlMs: 6 * HOUR_MS,
    collectionStaleIfErrorMs: 48 * HOUR_MS,
    uprnTtlMs: 30 * DAY_MS
});

const isUpstreamError = (error) => error instanceof UpstreamError;

/**
 * Validation, caching and error mapping in front of a BinCollectionProvider.
 * Knows nothing about how the provider talks to its council.
 */
export class BinsService {
    constructor({ provider, cacheConfig = CACHE_DEFAULTS, clock = Date.now, metrics = null }) {
        this.provider = provider;
        this.clock = clock;
        this.addresses = new StaleWhileErrorCache({
            name: 'addresses',
            ttlMs: cacheConfig.addressTtlMs,
            staleIfErrorMs: cacheConfig.addressTtlMs,
            clock,
            metrics
        });
        this.collections = new StaleWhileErrorCache({
            name: 'collections',
            ttlMs: cacheConfig.collectionTtlMs,
            staleIfErrorMs: cacheConfig.collectionStaleIfErrorMs,
            clock,
            metrics
        });
        this.uprns = new StaleWhileErrorCache({
            name: 'uprns',
            ttlMs: cacheConfig.uprnTtlMs,
            clock,
            metrics
        });
    }

    async lookupAddresses(rawPostcode) {
        const postcode = normalizePostcode(rawPostcode);
        if (!postcode) throw new ApiError('INVALID_POSTCODE', 400, 'That is not a valid UK postcode');

        const { value: addresses } = await this.addresses.get(
            postcode,
            () => this.provider.lookupAddresses(postcode),
            { canServeStale: isUpstreamError }
        );
        if (addresses.length === 0) {
            throw new ApiError('NO_ADDRESSES_FOUND', 404, 'No addresses were found for that postcode');
        }
        return { postcode, addresses };
    }

    async getCollections(propertyId) {
        if (!isNumericId(propertyId)) throw new ApiError('INVALID_PROPERTY_ID', 400, 'Invalid property ID');

        const result = await this.collections.get(
            propertyId,
            async () => {
                const collections = await this.provider.getCollections(propertyId);
                // WasteWorks answers unknown properties with an empty calendar.
                // If we already know a schedule for this property, treat an
                // empty one as a transient upstream fault rather than wiping it.
                if (collections.length === 0 && this.collections.peek(propertyId)) {
                    throw new UpstreamError('EMPTY_CALENDAR_FOR_KNOWN_PROPERTY');
                }
                return collections;
            },
            {
                canServeStale: isUpstreamError,
                shouldStore: (collections) => collections.length > 0
            }
        );
        if (result.value.length === 0) {
            throw new ApiError('PROPERTY_NOT_FOUND', 404, 'No collections were found for that property');
        }

        return {
            propertyId,
            collections: result.value,
            lastUpdated: new Date(result.storedAt).toISOString(),
            stale: result.stale
        };
    }

    async resolveUPRN(uprn) {
        if (!isNumericId(uprn)) throw new ApiError('INVALID_UPRN', 400, 'Invalid UPRN');
        if (typeof this.provider.resolveUPRN !== 'function') {
            throw new ApiError('NOT_SUPPORTED', 404, 'UPRN lookup is not supported for this council');
        }

        const { value: propertyId } = await this.uprns.get(
            uprn,
            () => this.provider.resolveUPRN(uprn),
            { canServeStale: isUpstreamError, shouldStore: (value) => value !== null }
        );
        if (!propertyId) throw new ApiError('PROPERTY_NOT_FOUND', 404, 'No property was found for that UPRN');
        return { uprn, propertyId };
    }
}
