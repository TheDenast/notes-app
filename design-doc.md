# notes-app — Censorship-Resistant Minimal Chat System

## Design Document

---

## 1. Problem Statement

Matrix/Synapse + Element is increasingly unreliable from Russia due to ISP-level blocking, mobile carrier filtering, and app store censorship risk. A private Synapse server is fingerprintable via well-known Matrix protocol endpoints (`/_matrix/client/versions`, `/.well-known/matrix/*`, `/_matrix/federation/v1/version`), making it detectable by automated IP sweeps.

A purpose-built minimal chat system is needed that:

- Is undetectable as a messaging service by network scanners
- Works from any device with a browser (critical for iOS users)
- Requires zero technical knowledge from end users
- Is operated and administered entirely by a single trusted admin

## 2. Threat Model

### In scope

- **Automated IP/domain scanning** — state-level port scanners probing for known protocol fingerprints
- **DNS/IP blocking** — domain or IP added to ISP blocklists (Roskomnadzor)
- **Mobile carrier filtering** — more aggressive blocking than fixed-line ISPs, especially VoIP/TURN traffic
- **App store removal** — inability to install native clients in the target country
- **Brute force attacks** — automated token guessing on the login endpoint
- **XSS/injection** — malicious content in user messages

### Out of scope

- Targeted state intelligence operations against this specific server
- Compromised end-user devices
- Coercion/legal compulsion of the admin
- Traffic analysis / correlation attacks

### Key principle

Security through obscurity of the deployment, not obscurity of the design. The source code is public. The security relies on: unknown domain, secret tokens, and unfingerprintable traffic. (Kerckhoffs's principle)

## 3. Architecture Overview

```
┌─────────────┐       HTTPS        ┌─────────────────┐
│   Browser    │ ◄────────────────► │   Go Backend     │
│  (any device)│   HTML + cookies   │                  │
│              │                    │  html/template   │
│  Vanilla TS  │                    │  SQLite          │
└─────────────┘                    └─────────────────┘
```

Single Go binary serving everything. No separate frontend build step at runtime, no microservices, no external dependencies at runtime.

## 4. Tech Stack

| Layer         | Choice                | Rationale                                          |
|---------------|-----------------------|----------------------------------------------------|
| Backend       | Go                    | Single binary, no runtime deps, stdlib HTTP server |
| Database      | SQLite                | Zero config, single file, embedded                 |
| Frontend      | `html/template`       | Server-side rendered, no build step                |
| Interactivity | TypeScript (vanilla)  | Single compiled JS file, no framework, type safety |
| TLS           | Let's Encrypt         | Auto-renewing, trusted certs                       |
| Hosting       | Any VPS               | Hetzner/OVH/Linode, avoid Russian jurisdiction     |

## 5. Cover Story

The application presents as a **self-hosted notes app** at `notes.<yourdomain>.com`.

- Landing page displays a title, favicon, and passphrase input — visually indistinguishable from Obsidian Publish, Trilium, Joplin, or any other self-hosted notes tool
- Source code is public on GitHub, reinforcing legitimacy
- Low traffic pattern is consistent with personal notes usage
- Valid TLS cert on an aged domain avoids automated flagging

## 6. Authentication

### Token Design

- Admin generates tokens offline via CLI: `./notes-app useradd --name "Mom"`
- Token: 32 bytes from `crypto/rand`, base64url encoded
- Token encodes nothing — it's a lookup key in the database
- Distributed to users out-of-band (phone call, SMS, email, in person)

### Login Flow

1. User opens `notes.<domain>.com`
2. Sees a "notes app" landing page with a passphrase field
3. Pastes token, submits via HTML form POST
4. Server validates against DB, sets session cookie:
   - `HttpOnly` — inaccessible to JS
   - `Secure` — HTTPS only
   - `SameSite=Strict` — no cross-site requests
   - Session ID: 32 bytes from `crypto/rand`
5. Redirect to contact list
6. Subsequent requests authenticated via cookie automatically

### Brute Force Protection

- Rate limit by IP: 5 failures → 15 min block, 20 failures → 24h block
- In-memory map of `IP → {count, blocked_until}`
- Token entropy (256 bits) makes brute force mathematically infeasible regardless

## 7. Data Model

```sql
CREATE TABLE users (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE sessions (
    id         TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NOT NULL
);

CREATE TABLE messages (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    sender_id  INTEGER NOT NULL REFERENCES users(id),
    receiver_id INTEGER NOT NULL REFERENCES users(id),
    body       TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_messages_conversation
    ON messages(sender_id, receiver_id, created_at);

CREATE INDEX idx_messages_receiver
    ON messages(receiver_id, sender_id, created_at);
```

Tokens stored as hashes (SHA-256 or bcrypt), never plaintext.

A periodic cleanup goroutine runs on startup to delete expired sessions:
`DELETE FROM sessions WHERE expires_at < CURRENT_TIMESTAMP`

## 8. API Endpoints

Initial page loads return full server-rendered HTML. Polling and send endpoints return JSON consumed by the TypeScript frontend.

| Method | Path                          | Auth     | Description                          |
|--------|-------------------------------|----------|--------------------------------------|
| GET    | `/`                           | None     | Landing page with token input        |
| POST   | `/auth`                       | None     | Validate token, set session cookie   |
| GET    | `/contacts`                   | Session  | List of other users                  |
| GET    | `/chat/{user_id}`             | Session  | Chat view with message history       |
| GET    | `/chat/{user_id}/messages`    | Session  | Poll for new messages (JSON)         |
| POST   | `/chat/{user_id}/send`        | Session  | Send a message                       |
| GET    | `/chat/{user_id}/history`     | Session  | Load older messages (JSON)           |
| POST   | `/logout`                     | Session  | Clear session cookie                 |

### Fingerprint resistance

- All other paths return generic 404
- No `/health`, `/api/version`, `/status`, or any metadata endpoints
- Response headers scrubbed: no `X-Powered-By`, no `Server` header
- 404 page matches the cover story aesthetic

## 9. Frontend Behavior

### Views

1. **Login** — "notes app" landing page, single passphrase field
2. **Contacts** — list of user names, click to open chat
3. **Chat** — message list + compose area at the bottom

### TypeScript Integration

- **New messages**: `setInterval` polling every 3s, fetches `/chat/{id}/messages?after={last_id}`, appends to message list
- **Send**: `fetch` POST on form submit, clears textarea on success
- **History**: scroll-to-top listener triggers fetch of `/chat/{id}/history?before={oldest_id}`, prepends older messages
- **No framework** — vanilla TS, single compiled `app.js` file served as static asset

### Message Rendering Security

- Message content inserted via `textContent`, never `innerHTML`, preventing XSS
- Messages display: sender name, timestamp, text content. Nothing else.

## 10. Admin CLI

All user management is command-line only. No admin web UI.

```
./notes-app useradd --name "Mom"          # prints token
./notes-app useradd --name "Brother"      # prints token
./notes-app userlist                       # lists users
./notes-app userdel --name "Mom"          # removes user + sessions
./notes-app revoke --name "Mom"           # invalidates sessions only
```

## 11. Deployment

### Structure

```
notes.yourdomain.com
├── notes-app          # single Go binary
├── notes-app.db           # SQLite database
├── .env               # domain, TLS config, secrets (gitignored)
└── static/
    ├── app.js         # compiled TypeScript output
    ├── style.css
    └── favicon.ico
```

### TLS

Let's Encrypt via autocert in Go stdlib, or Caddy/nginx reverse proxy. Either works. Reverse proxy adds a layer between the internet and the Go process.

### DNS

- Subdomain `notes` on an existing aged domain
- Cloudflare proxy optional but not necessary for phase 1
- A record pointing to VPS IP

### Backup

SQLite file only. Copy it off-server periodically. Encrypted at rest if paranoid (SQLCipher or filesystem-level encryption).

## 12. Phased Implementation Plan

Each step produces something independently runnable and testable. Don't move to the next step until the current one works. Packages to reach for are from Go stdlib unless otherwise noted.

---

### Phase 1 — Working MVP

**Goal: family can exchange text messages.**

#### Step 1 — Project skeleton + HTTP server
- `go mod init github.com/yourname/notes-app`
- Create `cmd/notes-app/main.go`
- Start a `net/http` server on a hardcoded port (e.g. 8080)
- Register one route: `GET /health` returning `200 OK`
- **Test**: `go run ./cmd/notes-app` then `curl localhost:8080/health`

#### Step 2 — DB connection + schema
- Add `modernc.org/sqlite` (pure Go, no CGo): `go get modernc.org/sqlite`
- Create `internal/db/db.go`
- On startup, open the SQLite file and run `CREATE TABLE IF NOT EXISTS` for `users`, `sessions`, `messages` (see section 7)
- **Test**: run the app, verify the `.db` file is created, inspect with `sqlite3 notes-app.db .tables`

#### Step 3 — Auth middleware + session handling
- Create `internal/auth/auth.go`
- Implement token validation: hash the incoming token with SHA-256, look it up in `users` table
- On success, generate a session ID (`crypto/rand`, 32 bytes, base64url encoded), store in `sessions`, set cookie
- Create `internal/middleware/middleware.go` with a session-check middleware that reads the cookie and rejects with `302 -> /` if invalid
- **Test**: insert a test user directly via `sqlite3`, then `curl -c cookies.txt -b cookies.txt` to verify login flow

#### Step 4 — Send message handler
- Create `internal/handler/handler.go`
- Implement `POST /chat/{user_id}/send`: read body, write to `messages` table with sender + receiver + timestamp
- Protect with auth middleware
- **Test**: `curl` with a valid session cookie, verify row appears in DB

#### Step 5 — Fetch messages handler
- Implement `GET /chat/{user_id}/messages?after={unix_timestamp}` returning JSON array of messages
- **Test**: send a message via step 4, then fetch it via this endpoint

#### Step 6 — HTML templates + static serving
- Create `templates/login.html`, `templates/contacts.html`, `templates/chat.html`
- Use `html/template` to render them from handlers
- Serve `static/` directory with `http.FileServer`
- Login page posts to `POST /auth`, on success redirects to `/contacts`
- Chat page renders last N messages server-side on initial load
- **Test**: open in browser, verify full login -> contacts -> chat flow works with manual page refresh

#### Step 7 — Admin CLI
- Create `cli/cli.go` with subcommands: `useradd`, `userdel`, `userlist`, `revoke`
- `useradd` generates a token (`crypto/rand`, 32 bytes, base64url), hashes it, stores in DB, prints plaintext token
- Wire into `main.go`: if `os.Args[1]` is a known subcommand, run CLI mode instead of starting the server
- **Test**: `./notes-app useradd --name "Mom"`, verify token printed and row exists in DB, use token to log in via browser

---

### Phase 2 — Usability

**Goal: feels like a real notes-style async messenger, no manual refresh.**

#### Step 8 — TypeScript frontend
- Create `frontend/app.ts` and `frontend/tsconfig.json`
- Implement a polling loop: `setInterval` every 3s, `fetch("/chat/{id}/messages?after={last_id}")`, append new messages to the DOM
- Implement send: intercept form submit, `fetch POST`, clear textarea on success
- Compile with `tsc`, output to `static/app.js`
- **Test**: open two browser tabs as different users, verify messages appear without refresh

#### Step 9 — History / infinite scroll
- Implement scroll-to-top listener in TS that fetches `/chat/{user_id}/history?before={oldest_id}` and prepends older messages
- **Test**: send enough messages to require scrolling, verify loading older messages works

#### Step 10 — UI polish
- Style `static/style.css` to match the notes app cover story aesthetic
- Muted colors, monospace or serif font, no chat bubbles — looks like a document editor
- **Test**: show it to someone unfamiliar with the project and ask what they think it is

---

### Phase 3 — Hardening

**Goal: production-grade security before sharing with family.**

#### Step 11 — Rate limiting
- In `internal/middleware/middleware.go`, add an in-memory IP-based rate limiter on `POST /auth`
- 5 failures -> 15 min block, 20 failures -> 24h block
- Use a `sync.Mutex`-protected map of `IP -> {count, blocked_until}`

#### Step 12 — Session expiry + cleanup
- Set `expires_at` on session creation (e.g. 30 days)
- On each authenticated request, reject expired sessions
- Start a goroutine in `main.go` that runs `DELETE FROM sessions WHERE expires_at < CURRENT_TIMESTAMP` every few hours

#### Step 13 — Response header scrubbing
- In middleware, remove `Server` header, add `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Strict-Transport-Security`
- Verify with `curl -I` that no identifying headers leak

#### Step 14 — Deploy
- Build: `GOOS=linux GOARCH=amd64 go build -o notes-app ./cmd/notes-app`
- Copy binary + `static/` + `templates/` to VPS
- Set up nginx or Caddy as reverse proxy with Let's Encrypt TLS
- Point `notes.<domain>.com` A record to VPS IP
- **Test**: full end-to-end from a phone on mobile data (not your home network)

---

### Phase 4 — Nice to have (future)

- Client-side E2EE
- Message expiry / auto-deletion
- Read receipts (seen timestamps)
- Multiple chat rooms / group messages
- File/image sharing (carefully — changes the traffic profile)
- Push notifications via web push API

## 13. Security Checklist

- [ ] Tokens: 32+ bytes, `crypto/rand`, stored as hashes
- [ ] Sessions: `crypto/rand` IDs, `HttpOnly`/`Secure`/`SameSite=Strict` cookies
- [ ] Input escaping: `textContent` only for user content in TS, `html/template` auto-escape on SSR pages
- [ ] SQL injection: parameterized queries only, no string concatenation
- [ ] Rate limiting: IP-based on `/auth` endpoint
- [ ] Headers: `X-Frame-Options: DENY`, no `Server` header, no version leaks
- [ ] Fingerprinting: no metadata endpoints, generic 404 for unknown paths
- [ ] TLS: valid Let's Encrypt cert, HTTPS only, HSTS header
- [ ] Secrets: `.env` file gitignored, tokens never logged

## 14. Repository Structure

```
notes-app/
├── cmd/
│   └── notes-app/
│       └── main.go          # entry point only, wires everything together
├── internal/
│   ├── db/
│   │   └── db.go            # connection, migrations
│   ├── auth/
│   │   └── auth.go          # token validation, session management
│   ├── handler/
│   │   └── handler.go       # HTTP handlers
│   └── middleware/
│       └── middleware.go    # rate limiting, auth check, header scrubbing
├── cli/
│   └── cli.go               # admin commands (useradd, userdel, etc.)
├── templates/
│   ├── login.html           # landing / token entry page
│   ├── contacts.html        # user list
│   └── chat.html            # chat view (initial SSR load)
├── frontend/
│   ├── app.ts               # TypeScript entrypoint
│   └── tsconfig.json
├── static/
│   ├── app.js               # compiled output, committed or built on deploy
│   ├── style.css
│   └── favicon.ico
├── .env.example
├── .gitignore
├── go.mod
├── go.sum
├── LICENSE
└── README.md
```

Estimated total: ~600 lines of Go + ~150 lines of HTML templates + ~150 lines of TypeScript.
