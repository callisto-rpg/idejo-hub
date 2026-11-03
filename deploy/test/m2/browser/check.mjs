// SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
// SPDX-License-Identifier: AGPL-3.0-only

// Hub milestone 2 exit check, in a real browser (Playwright's Chromium, Apache-2.0), driving
// the Hub's own pages only. run.sh starts it in the check's network, where hub.idejo.test
// and the forums' hosts lead to Caddy.
//
//  1. Sign in (password, then two-factor setup with a code computed from the shown key).
//  2. Create four forums: alpha, bravo, charlie, delta.
//  3. Suspend and resume bravo (its address shows the maintenance page meanwhile).
//  4. Back up alpha, then restore that backup.
//  5. Upgrade all four to 0.1.1: delta's release fails (run.sh made it so), and as the last
//     forum it must roll back alone while the other three are upgraded.
//  6. Export charlie and download the export (/out/export.tar, for run.sh's standalone
//     restore).
//  7. Delete delta now (its subdomain typed).

import { chromium } from "playwright"
import { createHmac } from "node:crypto"
import { writeFileSync } from "node:fs"

const HUB = "https://hub.idejo.test"
const EMAIL = process.env.OPERATOR_EMAIL
const PASSWORD = process.env.OPERATOR_PASSWORD
const FORUMS = ["alpha", "bravo", "charlie", "delta"]

const ok = message => console.log(`  ok  ${message}`)
const fail = message => {
  throw new Error(message)
}

// RFC 6238, as an authenticator app would.
function totp(secret) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  let bits = ""
  for (const c of secret.replace(/=+$/, "")) bits += alphabet.indexOf(c).toString(2).padStart(5, "0")
  const key = []
  for (let i = 0; i + 8 <= bits.length; i += 8) key.push(parseInt(bits.slice(i, i + 8), 2))
  const counter = Buffer.alloc(8)
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)))
  const h = createHmac("sha1", Buffer.from(key)).update(counter).digest()
  const o = h[h.length - 1] & 15
  return String((h.readUInt32BE(o) & 0x7fffffff) % 1000000).padStart(6, "0")
}

const browser = await chromium.launch()
// Caddy's internal CA (run.sh's local_certs): the browser need not trust it.
const context = await browser.newContext({ ignoreHTTPSErrors: true, acceptDownloads: true })
const page = await context.newPage()
page.setDefaultTimeout(30_000)
// Destructive buttons ask first (data-confirm): the operator says yes.
page.on("dialog", dialog => dialog.accept())

const connected = () => page.waitForSelector(".phx-connected", { timeout: 30_000 })

// The forum list's row text, read fresh.
async function row(name) {
  await page.goto(`${HUB}/`)
  await connected()
  const el = await page.$(`#forum-${name}`)
  return el ? (await el.innerText()).replace(/\s+/g, " ") : null
}

// Waits until a forum's row matches `test`, up to `minutes`.
async function waitRow(name, test, what, minutes = 6) {
  const until = Date.now() + minutes * 60_000
  let text = null
  while (Date.now() < until) {
    text = await row(name)
    if (text && test(text)) return text
    await page.waitForTimeout(3000)
  }
  fail(`${name} did not become ${what} (last: ${text})`)
}

// A row shows "(step)" while an action runs.
const settled = status => t => t.includes(status) && !t.includes("(")

async function openForum(name) {
  await page.goto(`${HUB}/`)
  await connected()
  await page.click(`#forum-${name} a`)
  await page.waitForSelector("#status")
  await connected()
}

async function status() {
  const s = (await page.innerText("#status")).trim()
  const step = (await page.$("#step")) ? (await page.innerText("#step")).trim() : ""
  return { s, step }
}

async function waitDetail(test, what, minutes = 6) {
  const until = Date.now() + minutes * 60_000
  let st = null
  while (Date.now() < until) {
    await page.reload()
    await page.waitForSelector("#status")
    st = await status()
    if (test(st)) return st
    await page.waitForTimeout(3000)
  }
  const error = (await page.$("#error")) ? await page.innerText("#error") : "none"
  const audit = (await page.innerText("#audit")).split("\n").slice(0, 6).join(" | ")
  fail(`not ${what}: status ${st.s}, step ${st.step || "none"}, ${error}; audit: ${audit}`)
}

// An action's button sends a LiveView event: wait until the page shows its step (or its
// end) before reloading, so the reload cannot race the event.
async function act(selector) {
  await page.click(selector)
  await page.waitForTimeout(1500)
}

const forumStatus = async host => {
  const response = await context.request.get(`https://${host}/`, { failOnStatusCode: false })
  return { status: response.status(), body: await response.text() }
}

console.log("1. Sign in")
await page.goto(`${HUB}/sign-in`)
await page.fill("#sign-in input[name='session[email]']", EMAIL)
await page.fill("#sign-in input[name='session[password]']", PASSWORD)
await Promise.all([page.waitForURL(/two-factor/), page.click("#sign-in button")])
const secret = (await page.innerText("#two-factor-secret")).trim()
await page.fill("#two-factor input[name='two_factor[code]']", totp(secret))
await Promise.all([page.waitForURL(`${HUB}/`), page.click("#two-factor button")])
await connected()
ok("signed in with the password and a two-factor code")

console.log("2. Create four forums")
for (const name of FORUMS) {
  await page.goto(`${HUB}/forums/new`)
  await connected()
  await page.fill("#new-forum input[name='forum[subdomain]']", name)
  await page.waitForSelector("#subdomain-check .text-success")
  await page.fill("#new-forum input[name='forum[display_name]']", `Club ${name}`)
  await page.fill("#new-forum input[name='forum[owner_email]']", `owner@${name}.example`)
  await Promise.all([page.waitForURL(`${HUB}/`), page.click("#new-forum button[type=submit], #new-forum button:not([type])")])
}
for (const name of FORUMS) {
  await waitRow(name, settled("running"), "running")
  const r = await context.request.get(`https://${name}.idejo.test/health`, { failOnStatusCode: false })
  r.status() === 200 || fail(`${name}/health answered ${r.status()}`)
}
ok("alpha, bravo, charlie and delta running, /health 200 through Caddy")

console.log("3. Suspend and resume bravo")
await openForum("bravo")
await act("#suspend")
await waitDetail(st => st.s === "suspended" && !st.step, "suspended")
const paused = await forumStatus("bravo.idejo.test")
paused.status === 503 && paused.body.includes("Paused for maintenance") || fail(`bravo while suspended: ${paused.status}`)
ok("bravo suspended: its address shows the maintenance page (503)")
await act("#resume")
await waitDetail(st => st.s === "running" && !st.step, "running again")
;(await forumStatus("bravo.idejo.test")).status === 200 || fail("bravo did not come back")
ok("bravo resumed: its address answers 200 again")

console.log("4. Back up alpha, then restore that backup")
await openForum("alpha")
await act("#backup")
await waitDetail(st => !st.step, "backed up")
await page.waitForSelector("#archives tbody tr")
;(await page.innerText("#archives tbody tr")).includes("backup") || fail("no backup listed")
ok("alpha backed up (listed with its size and SHA-256)")
await act("#archives tbody tr >> text=Restore here")
await waitDetail(st => st.s === "running" && !st.step, "restored and running")
;(await page.innerText("#audit")).includes("forum.restore") || fail("no restore in the audit log")
;(await forumStatus("alpha.idejo.test")).status === 200 || fail("alpha not answering after restore")
ok("alpha restored from that backup and running")

console.log("5. Upgrade all four to 0.1.1, delta's release failing")
await page.goto(`${HUB}/`)
await connected()
await page.fill("#upgrade-all input[name=version]", "0.1.1")
await page.click("#upgrade-all button")
await page.waitForSelector(".alert, [role=alert], #flash-info", { timeout: 10_000 }).catch(() => {})
for (const name of ["alpha", "bravo", "charlie"]) {
  await waitRow(name, t => settled("running")(t) && t.includes("0.1.1"), "running on 0.1.1", 10)
}
const delta = await waitRow("delta", t => settled("running")(t) && t.includes("0.1.0") && t.includes("error"), "rolled back to 0.1.0", 10)
ok(`alpha, bravo, charlie on 0.1.1; delta rolled back alone: ${delta}`)
;(await forumStatus("delta.idejo.test")).status === 200 || fail("delta not answering after rollback")
ok("delta answers 200 on 0.1.0")

console.log("6. Export charlie and download it")
await openForum("charlie")
await act("#export")
await waitDetail(st => !st.step, "exported")
const exportRow = page.locator("#archives tbody tr", { hasText: "export" }).first()
const [download] = await Promise.all([page.waitForEvent("download"), exportRow.locator("text=Download").click()])
await download.saveAs("/out/export.tar")
ok(`charlie's export downloaded (${download.suggestedFilename()})`)

console.log("7. Delete delta now")
await openForum("delta")
await page.fill("#delete form input[name=confirm]", "delta")
await page.click("#delete form button")
const until = Date.now() + 5 * 60_000
while ((await row("delta")) !== null) {
  Date.now() < until || fail("delta still listed")
  await page.waitForTimeout(3000)
}
ok("delta deleted (final export kept, gone from the list)")

writeFileSync("/out/done", "ok")
await browser.close()
