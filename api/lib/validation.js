const DIGITS = /^[0-9]{1,15}$/;

/** WasteWorks property IDs are plain positive integers. */
export function isNumericId(input) {
    return typeof input === 'string' && DIGITS.test(input) && !/^0+$/.test(input);
}
