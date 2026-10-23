// Open a walkthrough.html (from make_walkthrough.py) and/or web/index.html with a scan zip in
// headless Chromium, wait for mesh coloring to finish, check for errors, save screenshots, and
// verify that the photo-colored mesh actually matches the photos (not the class-grey fallback).
//
// usage: node tests/viewer_smoke.mjs <walkthrough.html> <out-dir> [scan.zip]
// needs: npm i playwright-core; uses $CHROMIUM_PATH, a browser under $PLAYWRIGHT_BROWSERS_PATH, or its own download
import { chromium } from 'playwright-core'
import { existsSync, readdirSync } from 'node:fs'
import path from 'node:path'
import http from 'node:http'
import { readFile } from 'node:fs/promises'

const [html, outDir, zip] = process.argv.slice(2)
const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..')

function chromiumPath() {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers'
  if (!existsSync(base)) return undefined // playwright-core's own download (npx playwright-core install chromium)
  for (const dir of readdirSync(base).filter((d) => d.startsWith('chromium-')).sort().reverse()) {
    for (const sub of ['chrome-linux/chrome', 'chrome-linux64/chrome']) {
      const p = path.join(base, dir, sub)
      if (existsSync(p)) return p
    }
  }
  return undefined
}

const browser = await chromium.launch({ executablePath: chromiumPath(), args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] })
let failures = 0

async function check(label, url, setup) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } })
  const errors = []
  page.on('pageerror', (e) => errors.push(String(e)))
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })
  await page.goto(url)
  if (setup) await setup(page)
  await page.waitForFunction(() => window.walkthrough, null, { timeout: 60000 })
  await page.waitForFunction(() => document.querySelector('.wt-status')?.hidden, null, { timeout: 120000 })
  await page.waitForTimeout(500)
  await page.screenshot({ path: path.join(outDir, `${label}-dollhouse.png`) })
  await page.evaluate(() => window.walkthrough.setMode('walk'))
  await page.waitForTimeout(400)
  await page.screenshot({ path: path.join(outDir, `${label}-walk.png`) })
  await page.evaluate(() => window.walkthrough.goToPhoto(0))
  await page.waitForTimeout(1500)
  await page.screenshot({ path: path.join(outDir, `${label}-tour.png`) })
  // the colored mesh must not be uniformly the class-grey placeholder
  const colored = await page.evaluate(() => {
    let n = 0, total = 0
    window.walkthrough.scene.traverse((o) => {
      const c = o.isMesh && o.geometry.getAttribute('color')
      if (!c) return
      for (let i = 0; i < c.count; i++) { total++; if (Math.abs(c.getX(i) - c.getY(i)) > 0.05 || Math.abs(c.getY(i) - c.getZ(i)) > 0.05) n++ }
    })
    return { n, total }
  })
  console.log(`${label}: ${colored.n}/${colored.total} vertices photo-colored; errors: ${errors.length}`)
  for (const e of errors) console.log('  ' + e)
  if (errors.length || colored.n < colored.total * 0.3) failures++
  await page.close()
}

await check('single-file', 'file://' + path.resolve(html))

if (zip) {
  // serve the repo so web/index.html can import ../ai-kit/walkthrough/*.js
  const server = http.createServer(async (req, res) => {
    const u = decodeURIComponent(new URL(req.url, 'http://x').pathname)
    const file = u === '/scan.zip' ? path.resolve(zip) : path.join(repo, u)
    if (!file.startsWith(repo) && file !== path.resolve(zip)) { res.writeHead(403).end(); return }
    try {
      const body = await readFile(file)
      const type = file.endsWith('.js') ? 'text/javascript' : file.endsWith('.html') ? 'text/html' : 'application/octet-stream'
      res.writeHead(200, { 'content-type': type }).end(body)
    } catch { res.writeHead(404).end() }
  }).listen(0)
  const port = server.address().port
  await check('web-app', `http://localhost:${port}/web/index.html?zip=/scan.zip`)
  server.close()
}

await browser.close()
process.exit(failures ? 1 : 0)
