#!/usr/bin/env python3
"""Reproduce the manual, source-backed catalog matching; no network or app edits."""
import collections
import hashlib
import json
from pathlib import Path
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CARDS_PATH = ROOT / "JustShoot/Resources/cards.json"
CARDS = json.loads(CARDS_PATH.read_text())["cards"]
GROUPS = collections.defaultdict(list)
for card in CARDS:
    GROUPS[(card["brand"], card["product"], card["iso"])].append(card)

RT = json.loads((HERE / "sources/rawtherapee-inventory.json").read_text())
FL = json.loads((HERE / "sources/film-luts-inventory.json").read_text())
SF = json.loads((HERE / "sources/spectral-film-lut-inventory.json").read_text())
SP = json.loads((HERE / "sources/spektrafilm-inventory.json").read_text())
FO = json.loads((HERE / "sources/fotufilm-inventory.json").read_text())
FILMS = {}
MATCHES = {}
RELATED = {}


def rt(filename):
    paths = [p for p in RT if p.rsplit("/", 1)[-1] == filename + ".png"]
    assert len(paths) == 1, (filename, paths)
    return {"source": "RawTherapee", "format": "Hald PNG", "file": paths[0],
            "url": "https://rawtherapee.com/shared/HaldCLUT.zip", "license": "CC-BY-SA-4.0",
            "kind": "open_lut", "input": "encoded sRGB", "requires": "convert Hald to cube/jslut"}


def source_model(source, filename):
    inventory, repo = {
        "Spectral Film LUT": (SF, "JanLohse/spectral_film_lut"),
        "spektrafilm": (SP, "andreavolpato/spektrafilm"),
        "Fotufilm": (FO, "DhaliwalX/fotufilm-engine"),
    }[source]
    all_paths = [f if isinstance(f, str) else f["file"] for f in inventory["files"]]
    paths = [p for p in all_paths if p.rsplit("/", 1)[-1] == filename]
    assert len(paths) == 1, (source, filename, paths)
    return {"source": source, "format": "model/profile", "file": paths[0],
            "commit": inventory["commit"],
            "url": f"https://github.com/{repo}/blob/{inventory['commit']}/{quote(paths[0])}",
            "license": "MIT" if source == "Spectral Film LUT" else "CC-BY-SA-4.0",
            "kind": "open_model", "input": "requires explicitly configured bake",
            "requires": "fixed exposure/white balance/output; disable spatial and scene-adaptive effects; bake and validate"}


def sfl(filename):
    return source_model("Spectral Film LUT", filename + ".py")


def fotu(filename):
    return source_model("Fotufilm", filename + ".json")


def spek(filename):
    return source_model("spektrafilm", filename + ".json")


def commercial(source, url, label, input_space="not independently verified"):
    return {"source": source, "format": ".cube (publisher listing)", "url": url,
            "file": label, "license": "app redistribution not cleared",
            "kind": "restricted_lut", "input": input_space,
            "requires": "obtain files and integration rights; validate transform; not purchased in this audit"}


def tone(label):
    return commercial("Tone Fuentes", "https://payhip.com/b/YlA1W", label,
                      "creative LUT; publisher says does not normalize LOG")


def andp(slug, label):
    return commercial("ANDP FilmStyles", "https://www.andpfilmstyles.com/product/" + slug + "/", label,
                      "publisher lists sRGB / Rec.709")


def bind(key, brand, iso, products):
    for product in products.split("|"):
        group = (brand, product, iso)
        assert group in GROUPS, group
        assert group not in MATCHES, group
        MATCHES[group] = key


def film(key, name, brand, iso, products, sources, resource=None, note=""):
    assert key not in FILMS
    FILMS[key] = {"id": key, "name": name, "sources": sources, "bundled_resource": resource, "note": note}
    bind(key, brand, iso, products)


# The match is to the named product, not a claim of a measured emulsion or vintage match.
film("ilford_hp5_plus_400", "Ilford HP5 Plus 400", "Ilford", 400, "HP5 Plus", [rt("Ilford HP5 Plus 400"), fotu("hp5plus400")], "IlfordHP5Plus400")
film("ilford_sfx_200", "Ilford SFX 200", "Ilford", 200, "SFX 200", [tone("Ilford SFX200")], note="Creative LUT; infrared filtration response is not recoverable from ordinary RGB.")
film("ilford_delta_100", "Ilford Delta 100 Professional", "Ilford", 100, "Delta 100 Professional", [rt("Ilford Delta 100")])
film("ilford_fp4_plus_125", "Ilford FP4 Plus 125", "Ilford", 125, "FP4 Plus", [rt("Ilford FP4 Plus 125"), fotu("fp4plus125")])
film("ilford_delta_3200", "Ilford Delta 3200 Professional", "Ilford", 3200, "Delta 3200 Professional", [rt("Ilford Delta 3200 2"), fotu("delta3200")])
film("ilford_xp2", "Ilford XP2 400", "Ilford", 400, "XP2", [rt("Ilford XP2")], note="XP2 Super is not counted under this older unsuffixed XP2 source.")
film("ilford_delta_400", "Ilford Delta 400 Professional", "Ilford", 400, "Delta 400 Professional", [rt("Ilford Delta 400")])
film("ilford_ortho_plus_80", "Ilford Ortho Plus 80", "Ilford", 80, "Ortho Plus", [tone("Ilford OrthoPlus")])
film("rollei_retro_80s", "Rollei Retro 80S", "Rollei", 80, "Retro 80S", [rt("Rollei Retro 80s")])

film("fuji_superia_400", "Fujifilm Superia 400", "Fujifilm", 400, "Fujicolor Superia", [rt("Fuji Superia 400 2"), fotu("superia400")])
film("fuji_pro400h", "Fujifilm Pro 400H", "Fujifilm", 400, "Fujicolor Pro 400H", [rt("Fuji 400H 2"), sfl("fuji_pro_400h")], "FujiPro400H")
film("fuji_velvia_50", "Fujifilm Velvia 50", "Fujifilm", 50, "Fujichrome Velvia", [rt("Fuji Velvia 50"), sfl("fuji_velvia_50")], "FujiVelvia50")
film("fuji_provia_100f", "Fujifilm Provia 100F", "Fujifilm", 100, "Fujichrome Provia 100F", [rt("Fuji Provia 100F"), sfl("fuji_provia_100f")], "FujiProvia100F")
film("fuji_superia_reala_100", "Fujifilm Superia Reala 100", "Fujifilm", 100, "Fujicolor Superia Reala", [rt("Fuji Superia Reala 100"), sfl("fuji_superia_reala")])
film("fuji_sensia_100", "Fujifilm Sensia 100", "Fujifilm", 100, "Fujichrome Sensia 100", [rt("Fuji Sensia 100")])
film("fuji_superia_200", "Fujifilm Superia 200", "Fujifilm", 200, "Fujicolor Superia|Superia 200", [rt("Fuji Superia 200"), fotu("superia200")])
film("fuji_superia_xtra_400", "Fujifilm Superia X-TRA 400", "Fujifilm", 400, "Fujicolor Superia X-TRA|Fujicolor Superia X-TRA 400", [sfl("fuji_superia_xtra_400"), spek("fujifilm_xtra_400")], "FujiSuperiaXTRA400")
film("fuji_natura_1600", "Fujifilm Natura 1600", "Fujifilm", 1600, "Fujicolor Natura 1600", [sfl("fuji_natura_1600")])
film("fuji_c200", "Fujifilm C200", "Fujifilm", 200, "Fujicolor C200", [sfl("fuji_c200"), fotu("c200")], "FujiC200")
film("fuji_provia_400x", "Fujifilm Provia 400X", "Fujifilm", 400, "Fujichrome Provia 400X", [rt("Fuji Provia 400X")])
film("fuji_fp100c", "Fujifilm FP-100C", "Fujifilm", 100, "FP-100C", [rt("Fuji FP-100c 3"), sfl("fuji_fp100c")])
film("fuji_instax_mini", "Fujifilm Instax Mini Color", "Fujifilm", 800, "Instax Mini", [fotu("instaxmini"), sfl("fuji_instax_color")])
film("fuji_provia_400f", "Fujifilm Provia 400F", "Fujifilm", 400, "Fujichrome Provia 400F Professional", [rt("Fuji Provia 400F")])
film("fuji_superia_100", "Fujifilm Superia 100", "Fujifilm", 100, "Fujicolor Superia 100", [rt("Fuji Superia 100 2")])
film("fuji_velvia_100", "Fujifilm Velvia 100", "Fujifilm", 100, "Fujichrome Velvia", [spek("fujifilm_velvia_100")], note="Velvia 100F is explicitly excluded.")
film("fuji_acros_ii", "Fujifilm Neopan ACROS 100 II", "Fujifilm", 100, "Neopan Acros 100 II", [fotu("acros100")], note="Profile ID is acros100 but the profile name is Acros 100 II; original ACROS LUT and camera ACROS mode are excluded.")

film("agfa_ultra_50", "Agfacolor Ultra 50", "Agfa", 50, "AgfaColor ULTRA 50", [andp("agfa-color-ultra-50", "Agfacolor Ultra 50")])
film("agfa_apx_100", "Agfa APX 100", "Agfa", 100, "APX|Agfapan APX 100", [rt("Agfa APX 100")])
film("agfa_vista_200", "Agfacolor Vista 200", "Agfa", 200, "AgfaColor Vista", [rt("Agfa Vista 200")], note="Vista Plus 200 is excluded because generation/manufacturer is not established.")
film("agfa_apx_25", "Agfapan APX 25", "Agfa", 25, "Agfapan  APX 25", [rt("Agfa APX 25")])
film("agfa_precisa_100", "Agfa CT Precisa 100", "Agfa", 100, "CT Precisa 100", [rt("Agfa Precisa 100")], note="Named product match; source does not establish the generation of the emulsion.")

film("kodak_gold_200", "Kodak Gold 200", "Kodak", 200, "Gold 200|Gold", [sfl("kodak_gold_200"), fotu("gold200")], "KodakGold200", "Historical Kodacolor Gold 200 and Gold II are excluded from the strict count.")
film("kodak_kodachrome_64", "Kodak Kodachrome 64", "Kodak", 64, "Kodachrome 64", [rt("Kodak Kodachrome 64"), sfl("kodachrome_64")], "KodakKodachrome64")
film("kodak_trix_400", "Kodak Tri-X 400", "Kodak", 400, "Tri-X 400|Tri-X 400 Pro", [rt("Kodak TRI-X 400 2"), sfl("kodak_trix_400")], "KodakTriX400", "Old Tri-X Pan and ISO 320 are tracked as related, not included here.")
film("kodak_kodachrome_25", "Kodak Kodachrome 25", "Kodak", 25, "Kodachrome 25", [rt("Kodak Kodachrome 25"), fotu("kodachrome25")])
film("kodak_tmax_100", "Kodak T-Max 100", "Kodak", 100, "TMAX 100", [rt("Kodak T-Max 100"), fotu("tmax100")], "KodakTMax100")
film("kodak_ultramax_400", "Kodak UltraMax 400", "Kodak", 400, "UltraMax", [sfl("kodak_ultramax_400"), fotu("ultramax400")])
film("kodak_ektar_100", "Kodak Ektar 100", "Kodak", 100, "Ektar 100", [rt("Kodak Ektar 100"), sfl("kodak_ektar_100")], "KodakEktar100")
film("kodak_colorplus_200", "Kodak ColorPlus 200", "Kodak", 200, "ColorPlus", [commercial("Pixflow", "https://pixflow.net/templates/colorama-kodak-colorplus-200/", "Colorama Kodak ColorPlus 200")])
film("kodak_portra_800", "Kodak Portra 800", "Kodak", 800, "Portra 800", [rt("Kodak Portra 800 2"), sfl("kodak_portra_800")], "KodakPortra800")
film("kodak_portra_160", "Kodak Portra 160", "Kodak", 160, "Portra 160", [rt("Kodak Portra 160 2"), sfl("kodak_portra_160")])
film("kodak_tmax_3200", "Kodak T-Max P3200", "Kodak", 3200, "TMAX P3200", [rt("Kodak TMAX 3200 2")])
film("kodak_e100", "Kodak Ektachrome E100 (still)", "Kodak", 100, "Ektachrome E100", [spek("kodak_ektachrome_100"), fotu("ektachromee100"), andp("kodak-ektachrome-e100", "Kodak Ektachrome E100")], note="The spektrafilm info explicitly says use=still. Spectral Film LUT's motion-picture 100D is excluded.")
film("kodak_e100vs", "Kodak Ektachrome E100VS", "Kodak", 100, "Ektachrome E100VS", [rt("Kodak Ektachrome 100 VS")])
film("kodak_portra_400nc", "Kodak Portra 400 NC", "Kodak", 400, "Portra 400NC", [rt("Kodak Portra 400 NC 2")])
film("kodak_elite_chrome_400", "Kodak Elite Chrome 400", "Kodak", 400, "Elite Chrome", [rt("Kodak Elite Chrome 400")])
film("kodak_portra_400", "Kodak Portra 400", "Kodak", 400, "Portra 400", [rt("Kodak Portra 400 2"), sfl("kodak_portra_400")], "KodakPortra400")
film("kodak_vericolor_iii", "Kodak Vericolor III 160", "Kodak", 160, "Vericolor III", [sfl("kodak_vericolor_iii")])
film("kodak_portra_400vc", "Kodak Portra 400 VC", "Kodak", 400, "Portra 400VC", [rt("Kodak Portra 400 VC 2")])
film("kodak_tmax_400", "Kodak T-Max 400", "Kodak", 400, "TMAX 400", [rt("Kodak T-Max 400")])
film("kodak_elite_chrome_200", "Kodak Elite Chrome 200", "Kodak", 200, "Ektachrome Elite 200", [rt("Kodak Elite Chrome 200")], note="Elite naming alias; source does not establish individual vintage emulsion revisions.")
film("kodak_portra_400uc", "Kodak Portra 400 UC", "Kodak", 400, "Portra 400UC", [rt("Kodak Portra 400 UC 2")])
film("kodak_kodacolor_100", "Kodak Kodacolor 100", "Kodak", 100, "Kodacolor 100", [fotu("kodacolor100")])
film("kodak_hie", "Kodak High Speed Infrared (HIE)", "Kodak", 80, "High Speed Infrared", [rt("Kodak HIE (HS Infra)")], note="Infrared spectral response and filter-specific effects cannot be reconstructed by a normal RGB LUT.")

film("polaroid_665", "Polaroid 665", "Polaroid", 80, "665", [rt("Polaroid 665 3")])
film("polaroid_669", "Polaroid 669", "Polaroid", 80, "669", [rt("Polaroid 669 3")])
film("polaroid_polachrome", "Polaroid PolaChrome 35mm", "Polaroid", 40, "PolaChrome 35mm", [rt("Polaroid Polachrome")])
film("konica_vx_200", "KonicaColor VX 200", "Konica", 200, "KonicaColor VX 200", [andp("konica-vx-200", "Konica VX 200")])

film("harman_phoenix_200", "Harman Phoenix 200 (first generation)", "Harman", 200, "Phoenix", [fotu("phoenix200"), {"source": "Bicyclelad", "format": ".cube", "file": "lut/phoenix200-punchy.cube; lut/phoenix200-flat.cube", "url": "https://bicyclelad.com/harman-phoenix-200-lightroom-preset-v2/", "kind": "restricted_lut", "license": "no app redistribution grant verified", "input": "Leica M10-P comparison; needs iPhone validation", "requires": "resolve redistribution rights"}], note="Existing 2026-10-24 download manifest confirms 64-cube files; does not cover Phoenix II.")
film("cinestill_800t", "CineStill 800T", "CineStill", 800, "800T", [fotu("cinestill800t"), commercial("PictureFX", "https://picturefx.itch.io/picturefx-cinestill-800t-v10", "PictureFX CineStill 800T", "validate on sRGB"), andp("cinestill-800t", "CineStill 800T")])
film("cinestill_400d", "CineStill 400Dynamic / 400D", "CineStill", 400, "400Dynamic", [fotu("cinestill400d")])
film("cinestill_50d", "CineStill 50D", "CineStill", 50, "50D", [commercial("SparkleStock", "https://www.sparklestock.com/downloads/cine/", "Cine 50D (5 variants)")])

film("lomo_turquoise", "Lomography LomoChrome Turquoise", "Lomography", None, "Lomochrome Turquoise", [fotu("lomochrometurquoise")])
film("lomo_purple", "Lomography LomoChrome Purple", "Lomography", None, "Lomochrome Purple", [fotu("lomochromepurple")])
bind("lomo_purple", "Lomography", 100, "Lomochrome Purple")
film("lomo_metropolis", "Lomography LomoChrome Metropolis", "Lomography", 100, "Lomochrome Metropolis", [fotu("lomochromemetropolis"), tone("LomoChrome Metropolis")])
film("lomo_color_92", "Lomography LomoChrome Color '92 400", "Lomography", 400, "Lomochrome Color'92|Lomochrome Color’92", [tone("LomoChrome Color92'")], note="Ross McConaghy also publishes a 1992 LUT; its Lumix recipe uses camera-specific settings and needs separate adaptation.")
film("lomo_fantome_8", "Lomography Fantome Kino 8", "Lomography", 8, "Fantome", [tone("Lomography Fantome Kino")])

# Re-spools count only where the catalog explicitly contains the original film code.
film("kodak_vision3_250d", "Kodak Vision3 250D / 5207", "Alien Film", 250, "5207/250D", [sfl("kodak_5207"), fotu("vision250d")])
bind("kodak_vision3_250d", "Three Film Rolls", 250, "5207")
film("kodak_doublex_5222", "Kodak Double-X / 5222", "Alien Film", 250, "5222/XX", [sfl("kodak_5222"), fotu("doublex5222")])
film("kodak_vision3_500t", "Kodak Vision3 500T / 5219", "Mutascan", 500, "Kodak Vision3 500T/5219", [sfl("kodak_5219"), spek("kodak_vision3_500t")])


def related(brand, iso, products, candidate, why):
    for product in products.split("|"):
        key = (brand, product, iso)
        assert key in GROUPS and key not in MATCHES and key not in RELATED, key
        RELATED[key] = {"candidate": candidate, "reason": why}


related("Ilford", 400, "XP2 Super", "Ilford XP2", "The verified LUT is unsuffixed XP2; Super revision not established.")
related("Ilford", 125, "FP4", "Ilford FP4 Plus 125", "Original FP4 is not FP4 Plus.")
related("Rollei", 200, "Infrared", "Rollei IR 400", "Catalog ISO 200 differs from LUT ISO 400; catalog identity needs verification.")
related("Fujifilm", 100, "Fujichrome Velvia 100F", "Fujifilm Velvia 100 / 50", "100F is a distinct product, not Velvia 100.")
related("Fujifilm", 200, "200", "Fujifilm C200 / Kodak Gold 200", "No original manufacturer or generation evidence for this particular 200 package.")
related("Fujifilm", 160, "Fujicolor NPS 160", "Fujifilm PRO 160NS / 160S", "NPS predecessor cannot automatically be equated to later PRO 160NS or PRO 160S.")
related("Fujifilm", 400, "Fujicolor Professional|Fujicolor Pro400|400|Superia Premium 400|Fujicolor Superia Multi400", "Pro 400H / Superia 400 / X-TRA 400", "Shared brand/ISO is insufficient to establish this product identity.")
related("Fujifilm", 400, "Fujichrome Provia 400 Professional", "Fujifilm Provia 400F / 400X", "Original Provia 400 is not verified as the F or X revision.")
related("Fujifilm", 200, "Fujichrome Sensia 200", "Fujifilm Sensia 100", "ISO mismatch.")
related("Agfa", 200, "Vista Plus 200", "Agfacolor Vista 200", "Vista and Vista Plus generations / manufacturing origins are not established as equal.")
related("Agfa", 400, "Agfapan APX 400", "Agfa APX 100 / 25", "ISO mismatch.")
related("Agfa", 50, "AgfaChrome 50 S", "Agfachrome RSX II 50", "Agfachrome 50 S is not the RSX II product.")
related("Agfa", 100, "AgfaChrome 100RS", "Agfachrome RSX II 100", "RS and RSX II are distinct generations.")
related("Kodak", 200, "Kodacolor Gold 200|Gold II", "Kodak Gold 200", "Historical named revision; strict vintage equivalence not established.")
related("Kodak", 400, "Ultra|Gold Ultra 400|Kodacolor VR Plus|MAX|FarbWelt 400|Advantix Ultra Max|Gold|Kodacolor Gold 400", "Kodak UltraMax 400", "Historical/rebranded/APS variants are not silently merged with modern UltraMax.")
related("Kodak", 400, "Tri-X Pan", "Kodak Tri-X 400", "Older Tri-X Pan packaging; source does not establish matching historical generation.")
related("Kodak", 320, "Tri-X Pan", "Kodak Tri-X 400", "ISO 320 TXP is a different stock.")
related("Kodak", 100, "Elite Chrome|Ektachrome Elite 100", "Kodak Elite ExtraColor 100 / Elite 100 XPRO", "ExtraColor and cross-processing are not the ordinary EB100 product.")
related("Kodak", 25, "Kodachrome II", "Kodachrome 25 (K-14)", "Kodachrome II uses an earlier generation/process; equal ISO does not imply equal product.")
related("Kodak", 10, "Kodachrome", "ANDP Kodachrome 35mm 1935-1962", "Broad historical look exists; matching ISO and specific generation not established.")
related("Kodak", None, "High Speed Infrared Film 2481", "Kodak HIE (HS Infra)", "Plausible HIE/2481 identity, but missing catalog ISO and exact source revision warrant manual review.")
related("Polaroid", 160, "Color SX-70 Film", "PictureFX Polaroid SX-70 Core LUT", "Vintage SX-70 look exists; current Polaroid Color chemistry/generation not established.")
related("Polaroid", 640, "Color 600 Film|Color 600 Film Round Frame|Color i-Type Film", "ANDP Polaroid 600", "ANDP describes 1980s-early-2000s film; modern 600/i-Type chemistry is not established as the same.")
related("Polaroid", 640, "990|Image Instant Film", "Polaroid PX-680 / 600", "Different named product; no exact source verified.")
related("Impossible Project", 160, "Color Instant Film for Polaroid SX-70 Type Cameras", "Polaroid PX-70 / SX-70 LUT", "Catalog lacks PX-70 identifier; modern/Impossible revision not established.")
related("Konica", 200, "Centuria 200", "ANDP Konica Centuria APS 200", "Project has 35mm; the available ANDP product is specifically APS.")
related("CineStill", None, "BWXX", "Kodak Double-X 5222", "Original-stock candidate; processing and scan differ; no verified CineStill BWXX LUT.")
related("Alien Film", 100, "Aeronega", "Kodak Aerocolor 2460", "Original-stock candidate only; catalog has no manufacturer code.")
related("SantaColor", 100, "SantaColor", "Kodak Aerocolor 2460", "Original-stock/rebrand assumption not counted as an exact named LUT.")
for product, iso, code in [("200T", 200, "5213"), ("250D", 250, "5207"), ("500T", 500, "5219"), ("50D", 50, "5203")]:
    related("Building 2", iso, product, "Kodak Vision3 " + code, "Likely re-spool, but catalog has no original manufacturer code.")
related("Reflx Lab", 250, "250D", "Kodak Vision3 5207", "No original manufacturer code in catalog; re-spool equivalence not counted.")
related("Reflx Lab", 800, "800T", "CineStill 800T / Vision3 5219", "Different manufacturer's processing and exposure rating.")
related("Reflx Lab", 400, "400D", "CineStill 400D", "Equal label/ISO across brands does not establish equal emulsion/processing.")
related("Space Cat Film", 250, "Mars 250D", "Kodak Vision3 5207", "Catalog says C-41; source model's native process is ECN-2.")
related("Mr. Negative", 250, "250D", "Kodak Vision3 5207", "No original manufacturer code in catalog.")
related("Mr. Negative", 250, "Eterna 250D", "Fujifilm Eterna 500", "Different ISO/type; no 250D LUT in verified source inventory.")
related("Harman", 200, "Phoenix II", "Harman Phoenix 200", "Second generation; first-generation model/LUT cannot be counted as matching.")
related("Lomography", 200, "Lobster Redscale Negative", "Lomography Redscale 100", "Different product and ISO/format.")


def tier(sources):
    for kind, result in [("open_lut", "open_lut"), ("open_model", "open_model"), ("restricted_lut", "restricted_lut")]:
        if any(s["kind"] == kind for s in sources):
            return result
    raise AssertionError(sources)


for value in FILMS.values():
    value["tier"] = tier(value["sources"])
    value["has_ready_lut_listing"] = any(s["kind"] != "open_model" for s in value["sources"])
    if value["bundled_resource"]:
        for suffix in [".cube", ".jslut"]:
            assert (ROOT / "JustShoot/Resources" / (value["bundled_resource"] + suffix)).is_file()

rows = []
for (brand, product, iso), cards in sorted(GROUPS.items(), key=lambda t: (t[0][0].casefold(), t[0][1].casefold(), str(t[0][2]))):
    key = (brand, product, iso)
    match = FILMS.get(MATCHES.get(key))
    rows.append({"brand": brand, "product": product, "iso": iso, "card_count": len(cards),
                 "card_ids": [c["id"] for c in cards], "formats": sorted({c["format"] for c in cards}),
                 "status": match["tier"] if match else "related_only" if key in RELATED else "not_verified",
                 "film_id": match["id"] if match else None,
                 "related": RELATED.get(key), "bundled": bool(match and match["bundled_resource"])})

summary = {}
for status in ["open_lut", "open_model", "restricted_lut", "related_only", "not_verified"]:
    selected = [r for r in rows if r["status"] == status]
    summary[status] = {"catalog_groups": len(selected), "cards": sum(r["card_count"] for r in selected),
                       "matched_models": len({r["film_id"] for r in selected if r["film_id"]})}

ready = [r for r in rows if r["film_id"] and FILMS[r["film_id"]]["has_ready_lut_listing"]]
summary["ready_lut_any_license"] = {"catalog_groups": len(ready), "cards": sum(r["card_count"] for r in ready),
                                    "matched_models": len({r["film_id"] for r in ready})}
model_only = [r for r in rows if r["film_id"] and not FILMS[r["film_id"]]["has_ready_lut_listing"]]
summary["external_model_only"] = {"catalog_groups": len(model_only), "cards": sum(r["card_count"] for r in model_only),
                                  "matched_models": len({r["film_id"] for r in model_only})}
open_routes = [r for r in rows if r["status"] in ("open_lut", "open_model")]
summary["open_source_routes"] = {"catalog_groups": len(open_routes), "cards": sum(r["card_count"] for r in open_routes),
                                 "matched_models": len({r["film_id"] for r in open_routes})}
summary["total_found_including_models"] = {"catalog_groups": len(MATCHES),
                                           "cards": sum(len(GROUPS[k]) for k in MATCHES), "matched_models": len(FILMS)}
summary["bundled_physical_films"] = {"matched_models": sum(bool(f["bundled_resource"]) for f in FILMS.values()),
                                     "catalog_groups": sum(r["bundled"] for r in rows),
                                     "cards": sum(r["card_count"] for r in rows if r["bundled"])}

# Six digital camera modes are distinct from physical stock identities above.
resources = ["FujiRawPROVIA", "FujiRawVelvia", "FujiRawASTIA", "FujiRawCLASSICCHROME", "FujiRawCLASSICNeg", "FujiRawACROS"]
for resource in resources:
    assert (ROOT / "JustShoot/Resources" / (resource + ".jslut")).is_file(), resource
summary["capture_presets"] = {"presets": 19, "bundled_luts": 19, "physical_film_presets": 13,
                               "digital_camera_simulations": 6, "simulation_resources": resources}
assert len(rows) == 401 and sum(r["card_count"] for r in rows) == 550
assert sum(summary[s]["catalog_groups"] for s in ["open_lut", "open_model", "restricted_lut", "related_only", "not_verified"]) == len(rows)
assert sum(summary[s]["cards"] for s in ["open_lut", "open_model", "restricted_lut", "related_only", "not_verified"]) == len(CARDS)
assert len({c["id"] for c in CARDS}) == 550
assert len(FILMS) == len(set(MATCHES.values()))

audit = {"date": "2026-11-04", "catalog": {"path": "JustShoot/Resources/cards.json", "sha256": hashlib.sha256(CARDS_PATH.read_bytes()).hexdigest(),
         "cards": len(CARDS), "groups_by_brand_product_iso": len(rows), "brands": len({c["brand"] for c in CARDS})},
         "counting_rule": "Named-product correspondence only, not measured accuracy. Different generations, ISO, original-stock assumptions and camera simulations are not silently merged. Model-only routes are counted separately from ready LUT assets. Push/pull/contrast variants do not increase model count.",
         "scope": "Lower bound from the inspected source inventories and publisher listings, not proof of worldwide non-existence for unmatched films. No purchase, no new LUT integration, no new rendering or device validation.",
         "summary": summary, "films": list(FILMS.values()), "catalog_groups": rows}
(HERE / "coverage.json").write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n")

LABELS = {"open_lut": "A 开放许可现成 LUT/Hald", "open_model": "B 开放模型，可烘焙 LUT", "restricted_lut": "C 现成 LUT，App 授权未解决", "related_only": "D 仅近似型号/版本或分装片候选", "not_verified": "E 本轮未确认对应 LUT"}
lines = ["JustShoot 全胶片 LUT 覆盖核查", "日期：2026-11-04", "", "结论",
         f"外部现成 LUT（含可转换的 Hald、免费或付费）：{summary['ready_lut_any_license']['matched_models']} 款，覆盖 {summary['ready_lut_any_license']['catalog_groups']} 组 / {summary['ready_lut_any_license']['cards']} 张卡片。",
         f"此外仅确认外部模型路径：{summary['external_model_only']['matched_models']} 款，覆盖 {summary['external_model_only']['catalog_groups']} 组 / {summary['external_model_only']['cards']} 张卡片。其中 C200、Gold 200、Superia X-TRA 400 在本项目已经烘焙并内置。",
         f"合计有资源对应：{len(FILMS)} 个独立命名型号，覆盖 {len(MATCHES)} 组 / {sum(len(GROUPS[k]) for k in MATCHES)} 张卡片。",
         f"具备开放许可来源的路径：{summary['open_source_routes']['matched_models']} 款（现成 Hald 或可烘焙模型），不表示已经完成 App 分发审核或观感验证。",
         "", "范围与口径", "550 张图鉴卡片；按品牌＋产品原名＋ISO 分成 401 组，涉及 96 个品牌。401 组不等于 401 种乳剂。",
         "相同型号的多个包装只算一款；推拉、浓淡、冷热等 LUT 变体不重复计数。",
         "这里的‘对应’指作者/文件明确点名该型号，不代表厂家认可、实测还原或历史年份完全一致。",
         "ISO/显式后缀不匹配、分装片原片推测、其他 App 的封闭滤镜和普通 Lightroom XMP 都不计作严格找到。",
         "本轮是已确认来源的下限，不证明尚未找到的型号在全网不存在。", "", "统计（A/B/C 互斥；现成文件不等于可立即用于本 App）"]
for status in LABELS:
    s = summary[status]
    lines.append(f"{LABELS[status]}：{s['matched_models']} 个匹配型号 / {s['catalog_groups']} 组 / {s['cards']} 张卡片")
for status in ["ready_lut_any_license", "external_model_only", "total_found_including_models", "bundled_physical_films"]:
    lines.append(status + "：" + json.dumps(summary[status], ensure_ascii=False))
lines += ["当前拍摄预设：19/19 已有内置 .jslut；13 个实体胶片型号＋6 个 FUJIFILM 数码机身模拟。",
          "fujiProvia100F 是历史保存 ID，实际映射数码 PROVIA；实体 Provia 100F 的 case 是 fujiSlideProvia100F。", "",
          "iPhone 与许可", "A：RawTherapee Hald PNG 标注 sRGB，可转换为 cube/jslut。保留 CC BY-SA 4.0、署名和修改说明；App 发布还需检查具体分发方式。",
          "B：模型不等于现成 LUT。必须固定输入/曝光/白平衡/相纸/输出，停用场景自适应与空间效果，再离线烘焙、检查灰阶/肤色/色域和预览成片一致性。",
          "Spectral Film LUT 为 MIT；Fotufilm 与 spektrafilm 的 profiles 为 CC BY-SA 4.0，代码许可另计。",
          "spektrafilm README 有过时的自定义许可说法；本轮固定提交的 profile 元数据及 SPEKTRAFILM_LICENSE.txt 明确写 CC BY-SA 4.0。正式分发应以固定文件核对。",
          "C：ANDP 普通购买明确不含 App 内嵌；Pixflow/SparkleStock/Tone Fuentes 的摄影商用不视为 App 分发许可。没有购买或联系作者。",
          "Film-Luts GitHub 虽有 MIT，但作者声明不拥有各 LUT；不能以仓库 MIT 覆盖上游素材权利。本轮优先引用 RawTherapee 原包。",
          "LUT 仅承载全局颜色/明暗变换，不能单独复现颗粒、卤化银、晕光或红外光谱响应。",
          "除已内置资源外，本轮只确认来源/命名/许可路径，没有对所有下载和模型做 iPhone 观感、文件解析或真机验证。", "", "已确认的独立型号"]
for i, f in enumerate(sorted(FILMS.values(), key=lambda f: f["name"].casefold()), 1):
    selected = [r for r in rows if r["film_id"] == f["id"]]
    lines.append(f"{i:02d}. {f['name']} | {LABELS[f['tier']]} | {len(selected)} 组 / {sum(r['card_count'] for r in selected)} 张" + (" | 已内置" if f["bundled_resource"] else ""))
    for source in f["sources"]:
        lines.append(f"    {source['source']} / {source['format']} / {source.get('file', '')} / {source['license']}\n    {source['url']}")
    if f["note"]:
        lines.append("    备注：" + f["note"])
lines += ["", "全部 401 组的逐项核对（原始产品名保留）"]
for i, row in enumerate(rows, 1):
    tail = FILMS[row["film_id"]]["name"] if row["film_id"] else json.dumps(row["related"], ensure_ascii=False) if row["related"] else "尚未确认；不能据此断言不存在"
    lines.append(f"{i:03d}. {row['brand']} | {row['product']} | ISO {row['iso']} | {row['card_count']} 张 | {LABELS[row['status']]} | {tail}")
(HERE / "REVIEW.txt").write_text("\n".join(lines) + "\n")
print(json.dumps(summary, ensure_ascii=False, indent=2))
