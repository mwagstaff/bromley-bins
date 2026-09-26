export const COLLECTION_TYPES = Object.freeze(['food', 'recycling', 'paper', 'refuse', 'garden', 'other']);

/**
 * Buckets a raw upstream collection name into a small set the apps can give an
 * icon. Presentation only: the raw name is always kept alongside it, and an
 * unrecognised name maps to "other" rather than being dropped.
 */
export function normalizeCollectionType(raw) {
    const value = String(raw ?? '').toLowerCase();

    if (value.includes('food')) return 'food';
    if (value.includes('garden') || value.includes('green waste')) return 'garden';
    // Checked before recycling so "Non-Recyclable Refuse" is not read as recycling.
    if (
        value.includes('refuse')
        || value.includes('general')
        || value.includes('non-recycl')
        || value.includes('residual')
    ) return 'refuse';
    if (value.includes('paper') || value.includes('card')) return 'paper';
    if (
        value.includes('recycl')
        || value.includes('glass')
        || value.includes('plastic')
        || value.includes('cans')
    ) return 'recycling';

    return 'other';
}

/**
 * A human label for a raw upstream name. WasteWorks suffixes every event with
 * " collection", which reads badly in a list of collections.
 */
export function collectionLabel(raw) {
    const trimmed = String(raw ?? '').trim();
    const label = trimmed.replace(/\s+collection$/i, '').trim();
    return label || trimmed;
}
