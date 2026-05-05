from playwright.sync_api import sync_playwright
import time

with sync_playwright() as pw:
    b = pw.chromium.launch(headless=True)
    p = b.new_page()
    p.goto('https://news.ycombinator.com/login')
    p.fill('input[name="acct"]', 'sparkbyte')
    p.fill('input[name="pw"]', '3Irbfgvs!')
    p.click('input[type="submit"]')
    p.wait_for_load_state('networkidle')
    print('After login URL:', p.url)
    print('Title:', p.title())
    # check if logged in by looking for logout link
    logout = p.query_selector('a[href="logout"]')
    print('Logged in:', logout is not None)
    # Print first 1000 chars of body
    body = p.inner_text('body')
    print('PAGE SNIPPET:', body[:500])
    b.close()
