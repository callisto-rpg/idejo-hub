// SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
// SPDX-License-Identifier: AGPL-3.0-only
//
// Hub milestone 3 exit check, the person's side (run by ../run.sh in Playwright's image).
// PHASE=join: sign up on the Hub's page, take Zitadel's invite from the email, choose a
// password, then join alpha and bravo through "Idejo ID" (each forum asks first).
// PHASE=delete: alpha shows the moderator role and bravo refuses the banned member; then the
// member's page lists both forums, and the member deletes their Idejo ID.

import { chromium } from "playwright"
import fs from "node:fs"

const { PHASE, EMAIL, PASSWORD, MAILPIT } = process.env
const ID = "https://id.idejo.test"
let shot = 0

function check(ok, message) {
  if (!ok) throw new Error(message)
  console.log(`  ok  ${message}`)
}

const browser = await chromium.launch()
const context = await browser.newContext({ ignoreHTTPSErrors: true })
const page = await context.newPage()

async function snap(label) {
  shot += 1
  const name = `/out/${PHASE}-${String(shot).padStart(2, "0")}-${label.replace(/[^a-z0-9]+/gi, "-")}`
  await page.screenshot({ path: `${name}.png`, fullPage: true }).catch(() => {})
  fs.writeFileSync(`${name}.html`, await page.content().catch(() => ""))
}

// Zitadel's own screens (invite, sign-in, optional second factor): fill what is empty, skip
// optional setup, go on, until the browser has left them.
async function throughZitadel(until) {
  for (let i = 0; i < 12; i++) {
    await page.waitForLoadState("networkidle").catch(() => {})
    const url = new URL(page.url())
    if (until(url)) return
    if (url.hostname !== "id.idejo.test" || !url.pathname.startsWith("/ui/v2/login")) {
      await page.waitForTimeout(1000)
      continue
    }
    await snap(`zitadel-${url.pathname.split("/").pop()}`)

    // An account already signed in: pick it.
    const account = page.getByText(EMAIL, { exact: false }).first()
    const skip = page.getByRole("button", { name: /skip|later|not now/i }).first()
    const passwords = page.locator('input[type="password"]')
    const text = page.locator('input[type="text"]:visible, input[type="email"]:visible, input:not([type]):visible')

    const choosePassword = page.getByText("Password", { exact: true }).first()

    if (url.pathname.includes("/authenticator/set") && (await choosePassword.isVisible().catch(() => false))) {
      // The invite offers a password or a passkey: a password here (a browser has no passkey).
      await choosePassword.click()
    } else if (await skip.isVisible().catch(() => false)) {
      await skip.click()
    } else if ((await passwords.count()) > 0) {
      for (let p = 0; p < (await passwords.count()); p++) {
        if (await passwords.nth(p).isVisible()) await passwords.nth(p).fill(PASSWORD)
      }
      await submit()
    } else if ((await text.count()) > 0 && (await text.first().inputValue()) === "") {
      await text.first().fill(EMAIL)
      await submit()
    } else if (url.pathname.includes("accounts") && (await account.isVisible().catch(() => false))) {
      await account.click()
    } else {
      await submit()
    }
    // Wait for Zitadel to move on (a submit may take a few seconds).
    const before = page.url()
    await page.waitForURL(u => u.toString() !== before, { timeout: 20000 }).catch(() => {})
  }
  await snap("stuck")
  throw new Error(`stuck in Zitadel at ${page.url()}`)
}

async function submit() {
  const button = page.locator('button[type="submit"]:visible').last()
  if ((await button.isVisible().catch(() => false)) && (await button.isEnabled().catch(() => false)))
    await button.click({ timeout: 5000 }).catch(() => {})
  else if (!(await button.isVisible().catch(() => false))) await page.keyboard.press("Enter")
}

async function inviteLink() {
  for (let i = 0; i < 30; i++) {
    const list = await (await fetch(`${MAILPIT}/api/v1/messages`)).json()
    const mail = (list.messages || []).find(m => (m.To || []).some(t => t.Address === EMAIL))
    if (mail) {
      const message = await (await fetch(`${MAILPIT}/api/v1/message/${mail.ID}`)).json()
      const body = `${message.HTML || ""} ${message.Text || ""}`.replace(/&amp;/g, "&")
      const link = body.match(/https:\/\/id\.idejo\.test\/ui\/v2\/login\/verify\?[^"'\s<>]+/)
      if (link) return link[0]
    }
    await new Promise(r => setTimeout(r, 2000))
  }
  throw new Error("no invite email from Zitadel")
}

async function signInTo(host) {
  await page.goto(`https://${host}/users/sign-in`)
  await page.click("#oidc-sign-in")
  await throughZitadel(url => url.hostname === host)
  await page.waitForLoadState("networkidle").catch(() => {})
  await snap(`${host}-back`)
  return new URL(page.url()).pathname
}

try {
  if (PHASE === "join") {
    await page.goto(`${ID}/account/sign-up`)
    await page.fill('input[name="signup[email]"]', EMAIL)
    await page.fill('input[name="signup[display_name]"]', "Mia")
    await page.click('#signup button')
    check((await page.textContent("#signup-sent")).includes(EMAIL), "signed up on the Hub's page with email and display name only")

    await page.goto(await inviteLink())
    await throughZitadel(url => url.hostname === "id.idejo.test" &&
      (url.pathname.includes("signedin") || !url.pathname.startsWith("/ui/v2/login")))
    await snap("after-invite")
    console.log("  ok  the invite email's link set a password at Zitadel")

    for (const host of ["alpha.idejo.test", "bravo.idejo.test"]) {
      const path = await signInTo(host)
      check(path === "/users/oidc/consent", `${host}: asked first, before any account is made`)
      const consent = await page.textContent("#oidc-consent")
      check(consent.includes(EMAIL) && consent.includes("Mia"), `${host}: says it receives the email and the display name "Mia"`)
      await page.click("#oidc-consent-join")
      await page.waitForURL(`https://${host}/`)
      await page.goto(`https://${host}/users/settings`)
      check(new URL(page.url()).pathname === "/users/settings", `${host}: joined and signed in through Idejo ID`)
    }
  }

  if (PHASE === "delete") {
    const ids = JSON.parse(fs.readFileSync("/out/ids.json", "utf8"))

    await signInTo("alpha.idejo.test")
    await page.goto(`https://alpha.idejo.test/u/${ids.alpha}`)
    const alphaRoles = await page.locator('ul[aria-label="Roles"] li').allInnerTexts()
    check(alphaRoles.some(r => /moderator/i.test(r)), `alpha: moderator (${alphaRoles.join(", ")})`)

    const bravoPath = await signInTo("bravo.idejo.test")
    const bravoFlash = await page.textContent("body")
    check(bravoPath === "/users/sign-in" && /banned/i.test(bravoFlash), "bravo: the same Idejo ID is refused, banned there")
    await page.goto(`https://alpha.idejo.test/users/settings`)
    check(new URL(page.url()).pathname === "/users/settings", "alpha: still active and signed in")

    await page.goto(`${ID}/account`)
    await page.click("#account-sign-in")
    await throughZitadel(url => url.hostname === "id.idejo.test" && url.pathname.startsWith("/account"))
    await page.waitForLoadState("networkidle").catch(() => {})
    await snap("account")
    check((await page.textContent("#account-person")).includes(EMAIL), "the member's page: signed in")
    const forums = await page.textContent("#account-forums")
    check(forums.includes("Club alpha") && forums.includes("Club bravo"), "the member's page lists both forums joined")

    if (await page.locator("#account-reauth").isVisible().catch(() => false)) {
      await page.click("#account-reauth")
      await throughZitadel(url => url.hostname === "id.idejo.test" && url.pathname.startsWith("/account"))
    }
    await page.fill('#delete input[name="email"]', EMAIL)
    await page.click("#delete button.btn-error")
    await page.waitForLoadState("networkidle").catch(() => {})
    await snap("deleting")
    check((await page.textContent("body")).includes("Deleting your Idejo ID"), "deleting the Idejo ID, forum accounts first")

  }
  fs.writeFileSync(`/out/${PHASE}.done`, "")
} catch (error) {
  await snap("failure")
  console.error(`  FAIL ${error.message}`)
  process.exitCode = 1
} finally {
  await browser.close()
}
