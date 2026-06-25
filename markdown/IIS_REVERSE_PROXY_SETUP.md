# IIS Reverse Proxy Setup — DeviceScope Dashboard on Port 443

**Goal:** Browser → `https://<your-fqdn>/` (port 443, AD CA cert) → IIS reverse proxy → Streamlit on `localhost:8501` (plain HTTP, no TLS at the Streamlit layer anymore).

This replaces the `config.toml` `sslCertFile`/`sslKeyFile` approach entirely — once IIS terminates TLS, Streamlit goes back to plain HTTP internally. Don't run both at once.

---

## 1. Prerequisites

Install on the server currently running the Streamlit NSSM service (IIS is meant to run on the *same* machine for this setup — simpler, and lets you lock port 8501 down to localhost-only):

1. **IIS role**, with the **WebSocket Protocol** feature explicitly enabled. This is not optional — Streamlit's UI is entirely driven by a persistent WebSocket connection; without this, the page loads once and then goes completely unresponsive (this is the #1 thing people miss).

   ```powershell
   Install-WindowsFeature -Name Web-Server -IncludeManagementTools
   Install-WindowsFeature -Name Web-WebSockets
   ```

   Or via Server Manager: **Add Roles and Features → Server Roles → Web Server (IIS) → Role Services → Application Development → ✅ WebSocket Protocol**.

2. **URL Rewrite module** — download and install from Microsoft's official IIS download page (`iis.net/downloads/microsoft/url-rewrite`). Not included with IIS by default.

3. **Application Request Routing (ARR)** — same download page (`iis.net/downloads/microsoft/application-request-routing`). This is what actually does the proxying; URL Rewrite is what tells it *where* to send requests.

4. **A certificate covering the FQDN you'll actually use in the browser.** If you already have a wildcard cert from your AD CA (e.g. `*.domain.local`), you almost certainly don't need a new one — see Step 2 below for converting/importing what you already have rather than requesting fresh. Just confirm the hostname you'll browse to is a real subdomain (e.g. `devicescope.domain.local`), not the bare apex domain — wildcards don't cover that. Domain-joined machines trust your AD CA automatically; non-domain-joined devices will see a browser warning unless the CA root is separately trusted there.

---

## 2. Get the certificate into IIS

**Check the Server Certificates list first** — IIS Manager → server name (top-level node) → Server Certificates. If your wildcard cert is already there (e.g. imported previously for another site on this same server), you may be able to skip everything below and go straight to Step 3. Before relying on it, confirm two things: the **Expiration Date** column shows a comfortably future date, and double-clicking the entry shows *"You have a private key that corresponds to this certificate"* at the bottom of the General tab — without the private key present, it can't be used for an HTTPS binding even though it looks fine in the list. If both check out, skip to Step 3 and select this existing entry when you create the binding.

If it's not already there, or doesn't have a usable private key: **you almost certainly do not need to create a new certificate from scratch.** A wildcard cert for `*.domain.local` is valid for any single-label subdomain — it isn't tied to a specific application, server, or role. The real work is converting it from the PEM format Streamlit reads directly into a PFX, then importing that into the Windows certificate store, since that's what IIS bindings actually require.

**One thing to check first:** a wildcard cert only covers subdomains (`devicedashboard.domain.local`), not the bare root domain itself (`domain.local`) — those are different things to a certificate. Make sure whatever FQDN you plan to actually browse to is a real subdomain, not the apex domain.

### 2a. Convert your existing PEM cert + key to PFX

You'll need OpenSSL to do this conversion — but **it doesn't need to be installed on the production server itself**. This is a pure offline file operation; do it on any machine that has OpenSSL (commonly already present via Git for Windows — `C:\Program Files\Git\usr\bin\openssl.exe` — check with `Get-Command openssl` before installing anything new), then just copy the resulting `.pfx` file to production for the import step in 2b, which is pure IIS GUI and needs no OpenSSL at all.

Run this from wherever your `cert.pem`/`key.pem` currently live:

```powershell
openssl pkcs12 -export -out devicedashboard.pfx -inkey key.pem -in cert.pem
```

- You'll be prompted to set an **export password** — this is only used during the import step below; it doesn't become a permanent password on the cert itself.
- **If your AD CA has an intermediate/issuing CA separate from the root** (a two-tier hierarchy), include the intermediate cert in the bundle so IIS presents the full chain — append `-certfile intermediate.pem` to the command above, where `intermediate.pem` contains the issuing CA's certificate. Domain-joined clients usually have this cached already via GPO either way, but it's best practice to include it regardless, especially for any non-domain-joined access down the road.

### 2b. Import the PFX into IIS

1. **IIS Manager → click the server name (top-level node)** → double-click **Server Certificates**.
2. In the **Actions** pane (right side), click **Import...**
3. **Certificate file:** browse to `devicedashboard.pfx`.
4. **Password:** the export password you set in 2a.
5. **Certificate store:** select **Personal**.
6. ✅ *Allow this certificate to be exported* — check this if you want the flexibility to re-export it later from IIS's own UI (e.g. for a future server move). Leave unchecked if your security policy prefers private keys not be re-exportable once imported. Either way, TLS itself works fine.
7. Click **OK**. The cert now appears in the Server Certificates list — give it a friendly name if it doesn't already show one you recognize.
8. When you set up the site binding in Step 3 below, select this certificate from the dropdown.

That's it — no CSR, no CA template, no waiting on approval. Skip straight to Step 3 of this guide.

---

### Alternative: create a brand-new dedicated certificate instead

Skip this entire section unless you have a specific reason to prefer a fresh, single-purpose cert over reusing the wildcard (e.g. a security policy against using wildcard certs for individual server bindings). This path requests a new cert directly from your AD CA through IIS:

1. **IIS Manager → server name (top-level node) → Server Certificates → Actions pane → Create Domain Certificate...**
2. **Distinguished Name Properties page:**
   - **Common name:** the exact FQDN you'll browse to (e.g. `devicedashboard.domain.local`) — this must match what people type in the browser.
   - **Organization:** your organization's legal name.
   - **Organizational unit:** your department (e.g. "IT") — optional but commonly filled in.
   - **City/locality, State/province, Country/region:** your real address details.
   - Click **Next**.
3. **Online Certification Authority page:**
   - Click **Select...** — IIS will enumerate Enterprise CAs discoverable via AD. Pick your internal Issuing CA.
   - **Friendly name:** a label for your own reference in IIS's cert list (e.g. `DeviceDashboard-2026`) — purely local, not part of the actual certificate.
4. Click **Finish.**

**What happens next depends on your CA's template configuration, and this is the part that varies by environment:**
- **If the certificate template used for this request is configured for auto-issuance**, IIS submits the CSR, the CA issues it immediately, and IIS imports it straight into the Personal store automatically — done, no further steps.
- **If the template requires manager approval**, the request will sit Pending on the CA. An administrator needs to open the **Certification Authority** console on the CA server → **Pending Requests** → right-click the request → **All Tasks → Issue**. The one-shot IIS wizard doesn't always cleanly complete this two-step flow — if it doesn't, fall back to IIS's older two-step method instead: **Server Certificates → Create Certificate Request...** (generates a CSR file to submit manually), then once issued, **Complete Certificate Request...** (imports the completed cert using the CSR's matching private key).

If you're not sure which behavior your CA will exhibit, that's a quick question for whoever manages your AD CA rather than something to guess at — but again, this entire alternative section is very likely unnecessary given you already have a valid, currently-in-use wildcard cert.

---

## 3. Create the IIS site

A dedicated site (rather than reusing Default Web Site) keeps this configuration isolated:

1. **IIS Manager → Sites → Add Website...**
   - **Site name:** `DeviceDashboard` (or whatever you prefer)
   - **Physical path:** any existing empty folder — this site never serves static files of its own, it's a pure proxy. `C:\inetpub\wwwroot` is fine.
   - **Binding:** Type `https`, Port `443`, Host name = your FQDN, SSL certificate = the one from Step 2.
2. *(Optional but recommended)* Add a second binding on port 80, then later add a URL Rewrite rule to redirect HTTP → HTTPS, so people who type the plain `http://` URL get bounced automatically.

---

## 4. Enable ARR's proxy function (commonly missed)

Installing ARR doesn't automatically turn on proxying — this is a separate, server-level switch:

1. **IIS Manager → click the server name (top-level node)** → double-click **Application Request Routing Cache**.
2. In the **Actions** pane (right side), click **Server Proxy Settings...**
3. Check **Enable proxy** → **Apply**.

If you skip this, the reverse-proxy rule in the next step will exist but silently fail to forward anything.

---

## 5. Add the reverse-proxy rule

1. Select your **DeviceDashboard** site → double-click **URL Rewrite**.
2. In the Actions pane, **Add Rule(s)...** → choose **Reverse Proxy** (this template only appears once ARR is installed).
3. Enter the target server: `localhost:8501`.
4. Leave **Enable SSL Offloading** checked — this means "IIS terminates HTTPS, forwards plain HTTP to the backend," which is exactly the architecture here (Streamlit doesn't need to know about TLS at all anymore).
5. Click OK. This auto-generates an inbound rule (rewriting all requests to `http://localhost:8501/{R:1}`) and an outbound rule (rewriting any response headers that reference the backend's own host/scheme, so nothing leaks the internal `localhost:8501` address back to the browser).

WebSocket upgrade requests are passed through automatically by ARR as long as the WebSocket Protocol feature from Step 1 is actually enabled — there's no separate rewrite rule needed for that part specifically.

---

## 6. Update Streamlit's own config

Now that IIS owns TLS termination, Streamlit should go back to plain HTTP, bound to localhost only (so port 8501 is no longer reachable from anywhere on the network except IIS, running on this same machine — a real security improvement, not just cosmetic):

In `.streamlit/config.toml`:

```toml
[server]
address = "127.0.0.1"
port = 8501
# sslCertFile and sslKeyFile REMOVED - IIS handles TLS now
```

Then restart the NSSM service so the change takes effect:

```powershell
Restart-Service <your-nssm-service-name>
```

---

## 7. Firewall

- Ensure inbound **443** is allowed (Windows Firewall + any network firewall in front of this server).
- Port **8501** no longer needs to be reachable from other machines — once Streamlit is bound to `127.0.0.1`, it physically can't be reached over the network anyway, but you can also remove/tighten any existing firewall rule that was opened for it.

---

## 8. Test

From a **domain-joined** machine (so the AD CA root is already trusted):

1. Browse to `https://<your-fqdn>/` — confirm no certificate warning and the dashboard loads.
2. **Confirm WebSocket is actually working, not just the initial page load** — click something interactive (e.g. toggle the 📊 Analytics section open). If the page loaded but nothing responds to clicks, that's the WebSocket Protocol feature from Step 1 not being enabled — the single most common point of failure in this whole setup.

---

## Common pitfalls, in order of likelihood

1. **WebSocket Protocol feature not installed/enabled** → page loads, then goes unresponsive. (Step 1)
2. **"Enable proxy" never checked at the server level** → ARR installed but nothing actually forwards. (Step 4)
3. **Cert SAN/CN doesn't match the FQDN typed in the browser** → cert warning even though the cert is valid and trusted.
4. **Non-domain-joined or external clients** → will see a trust warning regardless of correct setup, since they don't have your AD CA root trusted unless that's been distributed to them separately. This is expected, not a misconfiguration.

---

## Worth considering while you're in here (not required, your call)

Since you're already setting up an IIS site in front of this dashboard for unrelated reasons (cert/port consolidation), this is also the natural foundation for **Windows Integrated Authentication** later, if you ever revisit automatic AD-based note attribution (discussed and declined earlier in this project's notes for cost/complexity reasons — see `PROJECT_REFERENCE.md`). You wouldn't need to set up a *new* proxy layer for that down the road; you'd just be turning on an auth feature on a site that already exists. Not something to do now — just worth knowing this groundwork doesn't get wasted if priorities change later.

---

## 9. The actual `config.toml` cutover (confirmed working in production)

Everything above gets IIS itself ready, but the dashboard won't actually work through it until the backend stops serving HTTPS directly — IIS's rewrite rule sends plain `http://localhost:8501/{R:1}`, and if Streamlit is still listening with `sslCertFile`/`sslKeyFil`e set, ARR sends an unencrypted request to a TLS-only port and you get a confusing `502.3 Bad Gateway` (`The server returned an invalid or unrecognized response`) — not because anything is misconfigured, but because of exactly this protocol mismatch.

**Before editing anything, check what's actually being passed on the command line right now:**
```powershell
nssm get DeviceScopeDashboard AppParameters
```

**This matters because of a real regression we hit:** if this service has ever been reinstalled/recreated (see `NSSM_GMSA_TROUBLESHOOTING.md` for why that might happen), the relaunch command may no longer include `--server.enableCORS false` even if it did originally — and unlike `enableXsrfProtection`, CORS was *only* ever being disabled via that command-line flag, not in `config.toml`. If it's silently missing, you will walk straight back into the original 403 WebSocket handshake error this whole guide exists to prevent. Don't assume it's still there — verify it.

**The actual edit**, commenting out (not deleting, for an easy rollback) the SSL lines, and explicitly adding `enableCORS = false` to `config.toml` itself so it no longer depends on a fragile command-line flag surviving a future service recreation:

```toml
[server]
headless = true
port = 8501
address = "0.0.0.0"
enableXsrfProtection = false
enableCORS = false
#sslCertFile = "C:\\Certificates\\Domain Wild Card\\cert.pem"
#sslKeyFile = "C:\\Certificates\\Domain Wild Card\\key.pem"
```

**Safe cutover sequence:**

1. Back up first: `Copy-Item .streamlit\config.toml .streamlit\config.toml.bak`
2. Make the edit above.
3. Restart the service, then test the **backend directly, in isolation, before involving IIS at all** — note this is now plain `http://`, not `https://`, since the backend no longer speaks TLS itself:
   ```powershell
   nssm restart DeviceScopeDashboard
   Invoke-WebRequest http://localhost:8501 -UseBasicParsing
   ```
4. Only once that returns `200`, test through IIS: `https://<your-fqdn>/`.
5. Confirm the WebSocket actually survives, not just the page load (same check as Step 8 above).
6. If anything goes wrong, rollback is one command: `Copy-Item .streamlit\config.toml.bak .streamlit\config.toml -Force; nssm restart DeviceScopeDashboard` — back to known-good direct `:8501` access immediately.
7. Once HTTPS-via-IIS is confirmed stable, let the old `:8501` direct-access habit fall away naturally rather than decommissioning anything on a deadline.

**Confirmed working in production as of 2026-06-23**, after also resolving an unrelated NSSM/gMSA service issue that surfaced during this same maintenance window — see `NSSM_GMSA_TROUBLESHOOTING.md` if the service itself won't start cleanly; that turned out to be completely unrelated to IIS, but is easy to conflate with an IIS problem if you hit both at once.