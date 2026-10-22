# Hostinger deployment preparation

This repository is the Quena Mart application only. The production target is
`https://mart.quena.store`; the existing `quena.store` site belongs to another
application and must remain a separate Hostinger website. Create `mart.quena.store`
as its own Node.js web app/subdomain in hPanel. Do not replace or redeploy the
apex-domain website.

## Runtime contract

- Application root: repository root.
- Branch currently checked out for production work: `main`.
- Install: `npm install` (uses the committed npm v3 lockfile).
- Build: `npm run build`.
- Start: `npm run start` (`next start`).
- Node: `>=22.0.0 <23` (select Node 22.x in hPanel).
- Do not set a fixed production port. Hostinger supplies `PORT`; `next start`
  uses it. Port `3001` is only the local development convention.

This is a server-rendered Next.js application. Do not choose static export or
the static-front-end deployment mode. The application uses Server Components,
Server Actions, Proxy, authenticated server reads, and dynamic customer routes.

Hostinger currently offers Node.js web-app deployment on eligible Business /
Unlimited and Cloud plans. Confirm the existing account plan has the Node.js
Web App option before deployment. Hostinger documents one long-running Node
process per app, a 120-second request limit, and no always-running background
workers, Docker, custom sidecar services, or custom listening ports. These
limits mean WAHA must remain external; Quena must not try to start it or run a
queue worker in the web app.

## Environment variables

Set these in the `mart.quena.store` app's environment in hPanel. Never put
secrets in Git, `NEXT_PUBLIC_*`, build logs, or client storage.

### Public / browser-safe

- `NEXT_PUBLIC_SUPABASE_URL` — existing production Supabase project URL.
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` — existing public anon key; RLS remains the
  security boundary.
- `NEXT_PUBLIC_APP_URL` — `https://mart.quena.store`; used to make absolute
  public member and digital receipt links.
- `NEXT_PUBLIC_SITE_URL` — `https://mart.quena.store`; used for Auth invitation
  redirects.

`NEXT_PUBLIC_*` values are embedded during the build. Configure them before
building/redeploying, not only after the app has started.

### Server secrets

- `SUPABASE_SERVICE_ROLE_KEY` — existing project's service-role key. Server
  only; never use the anon key's variable name for it or prefix it with
  `NEXT_PUBLIC_`.
- `IPOS_IMPORT_WORKER_SECRET` — required only to invoke the protected internal
  import worker route.
- `IPOS_COMMIT_SECRET` — required only to invoke the protected iPos commit
  route.
- `IPOS_PREFLIGHT_SECRET` — required only to invoke the protected iPos
  preflight route.

Generate independent high-entropy values for the three internal route secrets.
Their routes fail closed if unset. Do not reuse Supabase credentials.

### Optional / leave unset for initial Hostinger deployment

- `SUPABASE_URL` — optional server-side alias; the app falls back to
  `NEXT_PUBLIC_SUPABASE_URL`.
- `WAHA_BASE_URL`, `WAHA_API_KEY` — optional server-only WAHA connection. Leave
  both unset in Hostinger until a private, authenticated remote path to WAHA is
  designed. `127.0.0.1:3000` on Hostinger would mean Hostinger itself, not the
  owner's Mac.
- `WAHA_SESSION_NAME` — optional server-only session name; defaults to
  `quena-mart`.
- `PORT` — set by the hosting platform; do not hard-code it.
- `NODE_ENV` — set by the hosting platform to `production`.

When WAHA is unset or unreachable, Quena renders a safe unavailable/error
provider state. Polling stops in `ERROR`, `UNKNOWN`, and `NOT_CONFIGURED`; it
continues only for active connection lifecycle states. POS, checkout, Members,
products, and inventory do not depend on WAHA. Automatic delivery remains
disabled in code until a separate delivery checkpoint; saved preference values
do not start a worker or send messages.

## Supabase Auth

Keep the existing managed production project. Before customer/staff sign-in at
the new origin, configure Supabase Auth with:

- Site URL: `https://mart.quena.store`
- Allowed redirect URL: `https://mart.quena.store/auth/confirm`
- Keep local development redirect URLs separately if still needed.

This repository does not change those Supabase settings. The service-role
client lives behind the server-only module; browser code uses only the public
URL and anon key.

## iPos upload smoke test

The app accepts a workbook up to 25 MiB and configures Next Server Actions for
26 MiB to leave multipart overhead. Supabase Storage also has a 25 MiB object
limit. Hostinger's own request/proxy body limit is plan/platform-specific and
must not be assumed from the Next.js setting. After deployment, verify that a
representative production-format iPos `.xls`/`.xlsx` file near the supported
size can be uploaded and that a file above 25 MiB is rejected cleanly. Do not
use an uncontrolled real import for this check: upload stores the workbook and
creates a durable import request. Arrange a dedicated, non-committed
verification request with the Owner; do not invoke the commit stage.

## Build and font note

`app/layout.tsx` uses `next/font/google` Geist. Next downloads/loads this font
during production build; a successful build therefore needs access to Google's
font source unless the required font asset is already cached. Do not remove or
replace Geist just to work around a transient build-network failure. The
production build should be run and its result checked before deployment.

## Owner hPanel checklist

1. Confirm the plan exposes **Websites → Create Website → Node.js Web App**.
2. Create a separate app for `mart.quena.store`; leave the existing
   `quena.store` / family-finance website untouched.
3. Connect only the Quena Mart repository and select `main`.
4. Choose Node `22.x`, npm, repository root, build command `npm run build`, and
   start command `npm run start`.
5. Add the environment variable names above in hPanel. Use the production
   Supabase values; leave all `WAHA_*` values unset.
6. Set the public URL variables to `https://mart.quena.store` before build.
7. Review the detected settings and build logs, then deploy manually. This
   preparation does not authorize an automatic deployment or DNS change.
8. After SSL is active, verify `/login`, `/member-quena`, `/member-quena/daftar`,
   `/struk/<valid-issued-token>`, staff role boundaries, and a representative
   iPos upload. Confirm `/whatsapp` reports WAHA unavailable without repeated
   polling and that no delivery is attempted.
