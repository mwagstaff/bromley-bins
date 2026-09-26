const UK_POSTCODE = /^[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}$/;
const DIGITS = /^[0-9]{1,15}$/;

/**
 * Canonicalises a UK postcode ("br31aa", "BR3  1AA" → "BR3 1AA").
 * Returns null for anything that cannot be a UK postcode, so we never send
 * junk to the council.
 */
export function normalizePostcode(input) {
    if (typeof input !== 'string') return null;
    const compact = input.toUpperCase().replace(/\s+/g, '');
    if (!UK_POSTCODE.test(compact)) return null;
    return `${compact.slice(0, -3)} ${compact.slice(-3)}`;
}

/** WasteWorks property IDs and UPRNs are plain positive integers. */
export function isNumericId(input) {
    return typeof input === 'string' && DIGITS.test(input) && !/^0+$/.test(input);
}
