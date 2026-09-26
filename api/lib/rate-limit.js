/**
 * Fixed-window per-client rate limiter. Deliberately simple: one process, one
 * small public API, and the aim is only to stop a single client from turning
 * the API into a way of hammering the council.
 */
export function rateLimit({ windowMs, max, route, clock = Date.now, metrics = null }) {
    const windows = new Map();

    return function rateLimitMiddleware(req, res, next) {
        const now = clock();
        const key = req.ip ?? 'unknown';
        let window = windows.get(key);
        if (!window || now >= window.resetAt) {
            window = { count: 0, resetAt: now + windowMs };
            windows.set(key, window);
        }
        window.count += 1;

        if (windows.size > 50_000) {
            for (const [candidate, value] of windows) {
                if (now >= value.resetAt) windows.delete(candidate);
            }
        }

        if (window.count > max) {
            metrics?.rateLimited.inc({ route });
            res.set('Retry-After', String(Math.ceil((window.resetAt - now) / 1_000)));
            res.status(429).json({ error: { code: 'RATE_LIMITED', message: 'Too many requests, try again shortly' } });
            return;
        }
        next();
    };
}
