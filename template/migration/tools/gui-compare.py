#!/usr/bin/env python3
"""GUI parity: compare a legacy screenshot against the migrated app's screenshot
and emit REVIEW EVIDENCE — a diff image, a side-by-side, and a similarity score.

This is an ADVISORY aid for the UI phase, not a hard gate. Migrating across UI
toolkits is never pixel-identical (fonts, anti-aliasing, layout engines differ),
so a fuzzy threshold must not block a slice the way the exact fixture parity for
core logic does (CLAUDE.md hard rule 4 is about deterministic core, not UI).
The artifacts go to the parity-auditor / a human to judge.

    python gui-compare.py LEGACY.png NEW.png [--out DIR] [--fail-under 0.90]

Exit 0 = comparison produced (regardless of score) unless --fail-under is set and
the score is below it (opt-in gating). Exit 2 = could not run (bad input / no
Pillow). Needs Pillow; uses numpy and scikit-image (SSIM) if present.
"""
import argparse
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.stderr.write("gui-compare: Pillow is required.  pip install pillow\n")
    sys.exit(2)

try:
    import numpy as np
except ImportError:
    np = None


def _pad(img, size):
    """Place img top-left on a white canvas of `size` so mismatched dimensions
    are preserved and visible rather than distorted by resizing."""
    canvas = Image.new("RGB", size, (255, 255, 255))
    canvas.paste(img.convert("RGB"), (0, 0))
    return canvas


def compare(legacy_path, new_path, out_dir):
    a = Image.open(legacy_path)
    b = Image.open(new_path)
    W, H = max(a.width, b.width), max(a.height, b.height)
    ca, cb = _pad(a, (W, H)), _pad(b, (W, H))

    if np is not None:
        aa = np.asarray(ca, dtype=np.int16)
        bb = np.asarray(cb, dtype=np.int16)
        per_pixel = np.abs(aa - bb).max(axis=2)          # worst channel diff / pixel
        mae = float(np.abs(aa - bb).mean())
        similarity = 1.0 - mae / 255.0
        pct_diff = float((per_pixel > 16).mean()) * 100.0
        diff_img = Image.fromarray(
            np.clip(per_pixel * 4, 0, 255).astype("uint8"), mode="L"
        ).convert("RGB")
    else:  # pure-Pillow fallback
        from PIL import ImageChops
        d = ImageChops.difference(ca, cb)
        hist = d.convert("L").histogram()
        mae = sum(i * n for i, n in enumerate(hist)) / max(1, sum(hist))
        similarity = 1.0 - mae / 255.0
        pct_diff = 100.0 * sum(hist[17:]) / max(1, sum(hist))
        diff_img = d.point(lambda x: min(255, x * 4))

    ssim = None
    try:
        from skimage.metrics import structural_similarity
        ga = np.asarray(ca.convert("L"))
        gb = np.asarray(cb.convert("L"))
        ssim = float(structural_similarity(ga, gb))
    except Exception:
        pass

    os.makedirs(out_dir, exist_ok=True)
    base = os.path.splitext(os.path.basename(new_path))[0]
    diff_path = os.path.join(out_dir, base + ".diff.png")
    cmp_path = os.path.join(out_dir, base + ".compare.png")
    diff_img.save(diff_path)

    # side-by-side: legacy | new | diff, with labels
    panel = Image.new("RGB", (W * 3 + 20, H + 24), (245, 245, 245))
    panel.paste(ca, (0, 24))
    panel.paste(cb, (W + 10, 24))
    panel.paste(diff_img, (W * 2 + 20, 24))
    draw = ImageDraw.Draw(panel)
    for x, label in ((0, "legacy"), (W + 10, "new"), (W * 2 + 20, "diff")):
        draw.text((x + 4, 6), label, fill=(20, 20, 20))
    panel.save(cmp_path)

    return {
        "size": (W, H),
        "similarity": similarity,
        "pct_diff": pct_diff,
        "ssim": ssim,
        "diff": diff_path,
        "compare": cmp_path,
    }


def _selftest():
    """Generate two images (identical, then perturbed) and sanity-check scores."""
    import tempfile
    d = tempfile.mkdtemp()
    Image.new("RGB", (60, 40), (0, 128, 255)).save(os.path.join(d, "a.png"))
    b = Image.new("RGB", (60, 40), (0, 128, 255))
    for x in range(0, 20):
        for y in range(0, 40):
            b.putpixel((x, y), (255, 0, 0))
    b.save(os.path.join(d, "b.png"))
    same = compare(os.path.join(d, "a.png"), os.path.join(d, "a.png"), d)
    diff = compare(os.path.join(d, "a.png"), os.path.join(d, "b.png"), d)
    ok = same["similarity"] > 0.999 and diff["similarity"] < same["similarity"] \
        and diff["pct_diff"] > 20.0 and os.path.exists(diff["compare"])
    print("gui-compare selftest:", "PASS" if ok else "FAIL",
          f"(identical={same['similarity']:.4f}, perturbed={diff['similarity']:.4f})")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Compare legacy vs new GUI screenshots (advisory).")
    ap.add_argument("legacy", nargs="?", help="legacy screenshot (PNG/JPG)")
    ap.add_argument("new", nargs="?", help="migrated-app screenshot")
    ap.add_argument("--out", default="migration/reference/diff", help="output dir for artifacts")
    ap.add_argument("--fail-under", type=float, default=None,
                    help="opt-in: exit 1 if similarity < this (default: advisory, exit 0)")
    ap.add_argument("--selftest", action="store_true", help="self-check and exit")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(_selftest())
    if not args.legacy or not args.new:
        ap.error("legacy and new screenshots are required (or use --selftest)")
    try:
        r = compare(args.legacy, args.new, args.out)
    except FileNotFoundError as e:
        sys.stderr.write(f"gui-compare: {e}\n")
        sys.exit(2)
    except Exception as e:  # unreadable / not an image / decode failure
        sys.stderr.write(f"gui-compare: cannot read images ({type(e).__name__}: {e})\n")
        sys.exit(2)

    print(f"canvas       : {r['size'][0]}x{r['size'][1]}")
    print(f"similarity   : {r['similarity']:.4f}  (1.0 = identical)")
    if r["ssim"] is not None:
        print(f"SSIM         : {r['ssim']:.4f}")
    print(f"pixels diff  : {r['pct_diff']:.1f}%")
    print(f"diff image   : {r['diff']}")
    print(f"side-by-side : {r['compare']}")
    print("verdict      : ADVISORY - review the side-by-side; UI parity is a human/auditor call.")

    if args.fail_under is not None and r["similarity"] < args.fail_under:
        sys.stderr.write(f"gui-compare: similarity {r['similarity']:.4f} < --fail-under {args.fail_under}\n")
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
