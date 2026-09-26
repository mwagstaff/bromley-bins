/**
 * In-memory cache with a freshness TTL, an extended stale-if-error window and
 * request coalescing, so concurrent misses for the same key cost the council
 * one request rather than many.
 */
export class StaleWhileErrorCache {
    constructor({ name, ttlMs, staleIfErrorMs = 0, maxEntries = 10_000, clock = Date.now, metrics = null }) {
        this.name = name;
        this.ttlMs = ttlMs;
        this.staleIfErrorMs = staleIfErrorMs;
        this.maxEntries = maxEntries;
        this.clock = clock;
        this.metrics = metrics;
        this.entries = new Map();
        this.inFlight = new Map();
    }

    /**
     * Returns `{ value, storedAt, stale }`. Serves a fresh entry directly;
     * otherwise loads, and if the load fails with an error `canServeStale`
     * accepts, falls back to an entry still inside the stale-if-error window.
     * Loaded values for which `shouldStore` returns false are returned but not
     * cached.
     */
    async get(key, load, { canServeStale = () => true, shouldStore = () => true } = {}) {
        const now = this.clock();
        const entry = this.#peek(key, now);

        if (entry && now - entry.storedAt < this.ttlMs) {
            this.#record('hit');
            return { value: entry.value, storedAt: entry.storedAt, stale: false };
        }

        try {
            const value = await this.#coalesce(key, load);
            const storedAt = this.clock();
            if (shouldStore(value)) {
                this.#set(key, { value, storedAt });
            }
            this.#record('miss');
            return { value, storedAt, stale: false };
        } catch (error) {
            const fallback = this.#peek(key, this.clock());
            if (fallback && canServeStale(error)) {
                this.#record('stale');
                return { value: fallback.value, storedAt: fallback.storedAt, stale: true };
            }
            this.#record('error');
            throw error;
        }
    }

    /** Returns an entry that is still within its stale-if-error window, if any. */
    peek(key) {
        return this.#peek(key, this.clock());
    }

    get size() {
        return this.entries.size;
    }

    #peek(key, now) {
        const entry = this.entries.get(key);
        if (!entry) return undefined;
        if (now - entry.storedAt >= this.ttlMs + this.staleIfErrorMs) {
            this.entries.delete(key);
            return undefined;
        }
        return entry;
    }

    #set(key, entry) {
        this.entries.delete(key);
        this.entries.set(key, entry);
        while (this.entries.size > this.maxEntries) {
            this.entries.delete(this.entries.keys().next().value);
        }
        this.metrics?.cacheEntries.set({ cache: this.name }, this.entries.size);
    }

    #coalesce(key, load) {
        let pending = this.inFlight.get(key);
        if (!pending) {
            pending = Promise.resolve()
                .then(load)
                .finally(() => this.inFlight.delete(key));
            this.inFlight.set(key, pending);
        }
        return pending;
    }

    #record(result) {
        this.metrics?.cacheRequests.inc({ cache: this.name, result });
    }
}
