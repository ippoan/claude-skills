#!/usr/bin/env node
// CDP Browser Automation Script
// Usage: node cdp.js <command> [options]
//
// Commands:
//   screenshot <output.png> [--selector <css>] [--full]
//   navigate <url> [--wait <ms>]
//   click <selector>
//   type <selector> <text>
//   eval <javascript>
//   tabs
//   html [--selector <css>]
//   pdf <output.pdf>
//   wait <selector> [--timeout <ms>]

const CDP_ENDPOINT = process.env.CDP_ENDPOINT || 'http://100.95.51.87:9223';

async function getPlaywright() {
  // Try multiple possible locations
  const paths = [
    'playwright',
    require('path').join(require('os').homedir(), '.npm/_npx/86170c4cd1c5da32/node_modules/playwright'),
    require('path').join(require('os').homedir(), '.npm/_npx/e41f203b7505f1fb/node_modules/playwright'),
  ];
  for (const p of paths) {
    try { return require(p); } catch {}
  }
  console.error('Error: playwright not found. Run: npm install -g playwright');
  process.exit(1);
}

async function main() {
  const args = process.argv.slice(2);
  const cmd = args[0];
  if (!cmd) {
    console.error('Usage: node cdp.js <command> [options]');
    console.error('Commands: screenshot, navigate, click, type, eval, tabs, html, pdf, wait');
    process.exit(1);
  }

  const { chromium } = await getPlaywright();
  const browser = await chromium.connectOverCDP(CDP_ENDPOINT);

  try {
    const contexts = browser.contexts();
    const pages = contexts.flatMap(c => c.pages());

    switch (cmd) {
      case 'tabs': {
        for (const [i, page] of pages.entries()) {
          console.log(`[${i}] ${page.url()} — ${await page.title()}`);
        }
        break;
      }

      case 'screenshot': {
        const page = pages[0];
        if (!page) { console.error('No page found'); process.exit(1); }
        const output = args[1] || '/tmp/cdp-screenshot.png';
        const selectorIdx = args.indexOf('--selector');
        const fullPage = args.includes('--full');
        if (selectorIdx !== -1 && args[selectorIdx + 1]) {
          const el = await page.locator(args[selectorIdx + 1]).first();
          await el.screenshot({ path: output });
        } else {
          await page.screenshot({ path: output, fullPage });
        }
        console.log(`Screenshot saved: ${output}`);
        break;
      }

      case 'navigate': {
        const page = pages[0];
        if (!page) { console.error('No page found'); process.exit(1); }
        const url = args[1];
        if (!url) { console.error('Usage: navigate <url>'); process.exit(1); }
        const waitIdx = args.indexOf('--wait');
        const waitTime = waitIdx !== -1 ? parseInt(args[waitIdx + 1]) : 0;
        await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
        if (waitTime > 0) await page.waitForTimeout(waitTime);
        console.log(`Navigated to: ${page.url()}`);
        console.log(`Title: ${await page.title()}`);
        break;
      }

      case 'click': {
        const page = pages[0];
        if (!page) { console.error('No page found'); process.exit(1); }
        const selector = args[1];
        if (!selector) { console.error('Usage: click <selector>'); process.exit(1); }
        await page.locator(selector).first().click();
        console.log(`Clicked: ${selector}`);
        break;
      }

      case 'type': {
        const page = pages[0];
        if (!page) { console.error('No page found'); process.exit(1); }
        const selector = args[1];
        const text = args.slice(2).join(' ');
        if (!selector || !text) { console.error('Usage: type <selector> <text>'); process.exit(1); }
        await page.locator(selector).first().fill(text);
        console.log(`Typed "${text}" into ${selector}`);
        break;
      }

      case 'eval': {
        const page = pages[0];
        if (!page) { console.error('No page found'); process.exit(1); }
        const js = args.slice(1).join(' ');
        if (!js) { console.error('Usage: eval <javascript>'); process.exit(1); }
        const result = await page.evaluate(js);
        console.log(JSON.stringify(result, null, 2));
        break;
      }

      case 'html': {
        const page = pages[0];
        if (!page) { console.error('No page found'); process.exit(1); }
        const selectorIdx = args.indexOf('--selector');
        if (selectorIdx !== -1 && args[selectorIdx + 1]) {
          const html = await page.locator(args[selectorIdx + 1]).first().innerHTML();
          console.log(html);
        } else {
          const html = await page.content();
          console.log(html);
        }
        break;
      }

      case 'pdf': {
        const page = pages[0];
        if (!page) { console.error('No page found'); process.exit(1); }
        const output = args[1] || '/tmp/cdp-page.pdf';
        await page.pdf({ path: output, format: 'A4' });
        console.log(`PDF saved: ${output}`);
        break;
      }

      case 'wait': {
        const page = pages[0];
        if (!page) { console.error('No page found'); process.exit(1); }
        const selector = args[1];
        if (!selector) { console.error('Usage: wait <selector>'); process.exit(1); }
        const timeoutIdx = args.indexOf('--timeout');
        const timeout = timeoutIdx !== -1 ? parseInt(args[timeoutIdx + 1]) : 10000;
        await page.locator(selector).first().waitFor({ timeout });
        console.log(`Found: ${selector}`);
        break;
      }

      default:
        console.error(`Unknown command: ${cmd}`);
        process.exit(1);
    }
  } finally {
    await browser.close();
  }
}

main().catch(e => { console.error(e.message); process.exit(1); });
