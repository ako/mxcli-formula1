#!/usr/bin/env python3
"""Log in and click through the race-results datagrid, marking each page.

Each click is bracketed by a marker written to the span file so the trace can be
sliced per page turn, and by a wall-clock measurement taken in the browser.
"""
import json
import sys
import time

from playwright.sync_api import sync_playwright

BASE = "http://frontend.local:8180"
CHROME = "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"
MARKS = sys.argv[1]
PAGES = int(sys.argv[2]) if len(sys.argv) > 2 else 4

marks = []


def mark(label):
    marks.append({"label": label, "t": time.time_ns()})


with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path=CHROME)
    page = browser.new_page(viewport={"width": 1400, "height": 1000})

    page.goto(f"{BASE}/", timeout=90000)
    # networkidle fires before Mendix has finished booting the client, so wait
    # on the form itself and then on the post-login page.
    page.wait_for_selector("#usernameInput", timeout=60000)
    page.fill("#usernameInput", "fan")
    page.fill("#passwordInput", "F1Enthusiast!2345")
    page.click("#loginButton")
    # Mendix may land on any /p/ page depending on the restored session.
    page.wait_for_function("() => !document.querySelector('#usernameInput')", timeout=90000)
    page.wait_for_timeout(3000)
    print("logged in:", page.title())

    mark("goto:results:start")
    page.goto(f"{BASE}/p/results", timeout=90000)
    page.wait_for_selector("css=.paging-status", timeout=90000)
    page.wait_for_function(
        "() => /of 27533/.test(document.querySelector('.paging-status')?.innerText || '')",
        timeout=90000,
    )
    mark("goto:results:end")
    print("first page:", page.inner_text("css=.paging-status").strip())

    # The pager's "next" control. Mendix renders it with an aria-label.
    next_btn = page.locator("button[aria-label='Go to next page']").first

    for i in range(1, PAGES + 1):
        mark(f"page{i}:start")
        t0 = time.time()
        next_btn.click()
        page.wait_for_function(
            "prev => document.querySelector('.paging-status')"
            "  && document.querySelector('.paging-status').innerText.trim() !== prev",
            arg=page.inner_text("css=.paging-status").strip(),
            timeout=90000,
        )
        dt = (time.time() - t0) * 1000
        mark(f"page{i}:end")
        status = page.inner_text("css=.paging-status").strip()
        print(f"  next #{i}: {status}   browser-observed {dt:.0f} ms")
        time.sleep(1.5)  # let the exporter flush between pages

    # Log out — a trial-licence runtime caps concurrent sessions, and every
    # abandoned Playwright login holds one until the runtime restarts.
    try:
        page.goto(f"{BASE}/xas/?action=logout", timeout=20000)
    except Exception:
        pass

    page.screenshot(path="/tmp/claude-0/-home-user-mxcli-formula1/"
                         "2417dbdb-fec6-5ec9-a108-f924d46aa801/scratchpad/paged.png",
                    full_page=False)
    browser.close()

with open(MARKS, "w") as f:
    json.dump(marks, f, indent=1)
print("marks written:", len(marks))
