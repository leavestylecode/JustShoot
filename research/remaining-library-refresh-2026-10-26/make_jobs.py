"""Create one independently referenced image_gen job for each remaining cover."""
import json
from collections import Counter
from setup_review import REPORT, ART, ROWS

COUNTS = Counter(c['brand'] for c in ROWS)
BRAND_NOTES = {
    'Ilford': 'Preserve this exact era of ILFORD typography and stock-specific panel colors. Modern white/black packaging uses its genuine speed accent, older cartons may be yellow, red, blue or green; do not impose modern packaging on historical stock.',
    'Agfa': 'Preserve the exact historical Agfa mark and this edition\'s red, blue, white, black or colored bands. Match the scanned version, not a generic modern red Agfa square.',
    'Polaroid': 'Keep authentic Polaroid era branding and rainbow geometry only where this precise package has it. Preserve white space and stock-specific dark/light or spectral color blocks; do not add a photograph or camera silhouette.',
    'Lomography': 'Keep this edition\'s distinctive color blocks, lettering and illustration motifs, simplified only enough for a calm square printed card. Do not replace all products with a common black template.',
    'Foma': 'Preserve actual Foma/Fomapan historical typography and the individual blue, magenta, black or white packaging bands in the supplied scan.',
    'CineStill': 'Preserve exact CineStill lettering, authentic red/blue/cream palette and stock-specific number treatment. ISO stock numbers are the headline; 120/135 and exposure count remain small technical footer.',
    'Harman': 'Match this exact Harman stock and edition, including actual Phoenix or other genuine palette and type. Do not insert Kodak/Fuji design elements.',
    'Rollei': 'Preserve the authentic Rollei red/white/black or edition-specific palette and stock name. Keep the characteristic mark and type without making them oversized.',
}
PRIORITY = 'MANDATORY LAYOUT OVERRIDE, stronger than packaging proportions and all reference images: this is a refined app collectible card, NOT an enlarged box panel. Put the one compact brand in the top 18percent header, with lettering only 6–8percent of total canvas height. Never a giant ILFORD/AGFA/POLAROID or other brand spanning the middle. Main FILM STOCK NAME is the hero, inside the central y=35–64percent region, with 2–3 lines at 11–14percent canvas height; generous quiet space above and below. All extra descriptions such as BLACK AND WHITE FILM are tiny supporting text (3percent height), never a separate large headline. Format/ISO/process footer is one small 24–28px caption at 1024px. Keep the exact edition palette and distinctive true shapes, but adapt the layout to this hierarchy. Flat ink, no 3D.\n\n'
BASE = '''Use case: illustration-story. Asset: ONE standalone square full-bleed flat printed film-cover illustration for a 110px collectible Library card, delivered as a crisp 1024x1024 image.
Input roles: Image 1 is the exact REAL PACKAGING SCAN for THIS catalog edition: authoritative for brand, typography, palette, key shapes and era. Read the actual main front panel; never reproduce the unfolded box, glue tabs or barcode. Image 2 is an approved Portra400 APP COVER: reference ONLY for delicate paper texture, generous margins, calm hierarchy and print finish. Image 3 is an approved Fuji APP COVER: secondary reference ONLY for the same restrained app finish. Do not borrow Kodak, Fujifilm, green, purple, gold, stock names or unrelated geometry from those style references.
Create a fresh refined square interpretation of the exact scanned packaging. Preserve its original visual identity and edition-specific dominant and accent colors; do not invent diversity or force all brands into a common color. Retain recognizable authentic type, stripes, bands, emblems and illustration when present. Adapt landscape/portrait packaging to square with careful spacing, not stretching. A historical monochrome label stays historical monochrome. An actual ornate historical design may retain its authentic ornament but no invented decorations.
Layout: one compact authentic brand identification total, normally 6–9percent of square height. Never duplicate the brand at top and bottom. Main exact film name is the strongest title, comfortably inset 7–8percent, usually centered within y=30–68percent; longest names use 2–4 clean lines rather than giant lettering. Title lines 10–15percent height maximum. Preserve stock speed where it is part of the actual product title. Keep genuine secondary color panels large enough to read as the product's key color.
All technical format, quantity, ISO, and process belong together in ONE consistent tiny footer, about 24–28px at 1024px, with 7–8percent bottom/right margin. Format numbers 120/220/620/135/110 and sheet dimensions must NEVER become an extra giant headline. Do not repeat the product name in the footer. Supporting words are small, not competing headlines. Product data below is authoritative for spelling; omit unknown metadata rather than inventing text.
Finish: flat printed ink and fine even paper fibers, minimal texture contrast, no blotches. Colors rich but restrained, consistent lightness with the approved references. No 3D, foil, bevel, metallic shine, extrusion, casting shadows, external frame, glossy plastic, plastic wrappers, perspective, folded carton, photographic mockup or lighting gradients. Outer corners square, image fills the whole canvas because the app adds its own rounded corners.
Never include JustShoot, RAW, sRGB, workflow arrows, simulation text, reference labels, captions, watermarks, invented slogans, expiration dates, barcodes, QR codes, noisy legal microtext, invented icons, film strips or color swatches. Do not create multiple covers, a grid or a contact sheet. Render ONLY the single requested cover. Exact brand and product spelling, no hallucinated numbers or suffixes.
'''

def main():
    jobs = []
    for c in ROWS:
        footer = [c['format']] if c['format'] not in ('Unknown', 'N/A', '') else []
        if c.get('quantity') not in (None, '', 'N/A', 'Unknown'): footer.append(str(c['quantity']))
        if c.get('iso') is not None: footer.append('ISO ' + str(c['iso']))
        if c.get('process') not in (None, '', 'N/A', 'Unknown'): footer.append(c['process'])
        direction = BRAND_NOTES.get(c['brand'], 'Use the exact scanned edition as the authority for palette, lettering and authentic motif. Preserve the brand\'s individuality while matching the approved app cards\' print finish and margins.')
        prompt = PRIORITY + BASE + f"\nEXACT BRAND: {c['brand']}\nEXACT PRODUCT TITLE: {c['product']}\nTINY TECHNICAL FOOTER ONLY: {' · '.join(footer)}\nPACKAGING TYPE: {c['subtype']}\nEDITION ART DIRECTION: {direction}\n"
        prompt += '\nFINAL CHECK: COMPACT BRAND IN HEADER 6–8percent height, HERO STOCK NAME IN CENTER 11–14percent per line, ONE TINY FOOTER; do not copy oversized brand proportions from the scan.\n'
        jobs.append({'id': c['id'], 'kind': 'generate', 'status': 'pending', 'brand': c['brand'], 'product': c['product'], 'prompt': prompt, 'references': [str(ART/'references'/(c['id']+'.jpg')), str(ART/'styles/cover_kodak_portra_400.png'), str(ART/'styles/cover_fuji_provia_100f.png')]})
    (REPORT/'jobs.json').write_text(json.dumps(jobs, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({'covers': len(jobs), 'brands': len(COUNTS), 'brandCounts': dict(COUNTS)}, ensure_ascii=False))

if __name__ == '__main__': main()
