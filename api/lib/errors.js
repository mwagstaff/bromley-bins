/**
 * An error the API can hand straight to a client: a stable `code` the app can
 * switch on, plus the HTTP status it maps to.
 */
export class ApiError extends Error {
    constructor(code, status, message = code) {
        super(message);
        this.name = 'ApiError';
        this.code = code;
        this.status = status;
    }
}

/**
 * Upstream failed in a way worth falling back to cached data for: network
 * failure, timeout, non-2xx status or a page/calendar we could no longer parse.
 * `reason` is for logs and metrics only and never reaches the client.
 */
export class UpstreamError extends ApiError {
    constructor(reason, { timeout = false, httpStatus, message } = {}) {
        super(
            timeout ? 'UPSTREAM_TIMEOUT' : 'UPSTREAM_ERROR',
            timeout ? 504 : 502,
            message ?? reason
        );
        this.name = 'UpstreamError';
        this.reason = reason;
        this.httpStatus = httpStatus;
    }
}

/** The upstream page or calendar no longer has the shape we depend on. */
export class ParserError extends UpstreamError {
    constructor(reason, message) {
        super(reason, { message });
        this.name = 'ParserError';
    }
}
