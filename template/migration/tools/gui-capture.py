#!/usr/bin/env python3
"""Optional web-capture helper for GUI parity: screenshot one page (legacy or
migrated) to a PNG so gui-compare.py can diff the two. Web apps only; for a
desktop/native legacy GUI, capture with your platform's tools (or the app's own
render-to-image) instead — gui-compare.py does not care how the PNG was made.

    python gui-capture.py --url http://localhost:8080/screen --out shot.png \
        [--viewport 1280x800] [--wait-selector "#ready"] [--wait-ms 500] [--full-page]

Needs Playwright:  pip install playwright  &&  playwright install chromium
Exit 0 = screenshot written. Exit 2 = Playwright missing or navigation failed.
Complex flows (login, multi-step navigation) are project-specific: write your own
capture using this as a starting point.
"""
import argparse
import sys


def main():
    ap = argparse.ArgumentParser(description="Screenshot a web page for GUI parity (advisory).")
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--viewport", default="1280x800", help="WxH")
    ap.add_argument("--wait-selector", default=None, help="wait for this CSS selector before shooting")
    ap.add_argument("--wait-ms", type=int, default=0, help="extra settle delay in ms")
    ap.add_argument("--full-page", action="store_true")
    args = ap.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        sys.stderr.write("gui-capture: Playwright is required.\n"
                         "  pip install playwright && playwright install chromium\n")
        sys.exit(2)

    try:
        w, h = (int(x) for x in args.viewport.lower().split("x"))
    except ValueError:
        ap.error("--viewport must look like 1280x800")

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            page = browser.new_context(viewport={"width": w, "height": h}).new_page()
            page.goto(args.url, wait_until="networkidle")
            if args.wait_selector:
                page.wait_for_selector(args.wait_selector)
            if args.wait_ms:
                page.wait_for_timeout(args.wait_ms)
            page.screenshot(path=args.out, full_page=args.full_page)
            browser.close()
    except Exception as e:  # navigation / launch failures
        sys.stderr.write(f"gui-capture: {e}\n")
        sys.exit(2)

    print(f"gui-capture: wrote {args.out} from {args.url}")


if __name__ == "__main__":
    main()
