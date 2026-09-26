import * as cheerio from 'cheerio';
import { ParserError } from '../errors.js';

const PROPERTY_ID = /^[0-9]+$/;
const collator = new Intl.Collator('en-GB', { numeric: true, sensitivity: 'base' });

/**
 * Parses the WasteWorks postcode results page.
 *
 * Returns the addresses (possibly empty when WasteWorks says it found nothing
 * for the postcode). Throws ParserError when the page is neither a results page
 * nor a "no results" page, so a markup change upstream is reported as an
 * upstream failure rather than silently telling users their postcode is empty.
 */
export function parseAddressResults(html) {
    const $ = cheerio.load(html);
    const select = $('select#address');

    if (select.length === 0) {
        const isPostcodeFormWithError = $('input[name="postcode"]').length > 0
            && $('.govuk-error-summary, .govuk-error-message').length > 0;
        if (isPostcodeFormWithError) return [];
        throw new ParserError('ADDRESS_SELECT_MISSING', 'No #address select in WasteWorks response');
    }

    const byId = new Map();
    select.find('option').each((_, element) => {
        const propertyId = ($(element).attr('value') ?? '').trim();
        const address = $(element).text().replace(/\s+/g, ' ').trim();
        if (!PROPERTY_ID.test(propertyId) || !address) return;
        if (!byId.has(propertyId)) byId.set(propertyId, { propertyId, address });
    });

    if (byId.size === 0) {
        throw new ParserError('NO_NUMERIC_OPTIONS', '#address select has no numeric property options');
    }

    // Upstream order is not guaranteed, so sort for a stable, natural order
    // ("Flat 2" before "Flat 10").
    return [...byId.values()].sort((a, b) => collator.compare(a.address, b.address));
}
