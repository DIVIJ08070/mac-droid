# TMJ Clinic CRM — Frontend Task Breakdown & Estimation

Scope: Authentication module + Lead Creation (stories received so far).
More modules will be appended as stories arrive.

Assumed stack: React + TypeScript SPA talking to the NestJS API.
Estimates assume 1 frontend developer, hours of focused work.

---

# 1. Frontend Application Flow

## 1.1 App Bootstrap (Session Restore)

Runs every time the app loads — first visit, refresh, or new tab.

```
App Loads
     │
     ▼
Read crm_token From localStorage
     │
    ┌┴────────────────┐
    │                 │
 Missing           Present
    │                 │
    ▼                 ▼
Redirect        GET /auth/me
/login                │
            ┌─────────┴─────────┐
            │                   │
        401 / Error           200 OK
            │                   │
            ▼                   ▼
     Clear crm_token      Store User In State
     + crm_user                 │
            │                   ▼
            ▼           Redirect / Render
       Redirect         Role Dashboard
       /login
```

## 1.2 Login Screen Flow

```
User Opens /login
     │
     ▼
Enter Email + Password
     │
     ▼
Click Sign In
     │
     ▼
Frontend Validation
(required, email format, trim)
     │
    ┌┴────────────────┐
    │                 │
 Invalid            Valid
    │                 │
    ▼                 ▼
Show Field      Disable Button
Errors          + Show Loading
(API not             │
 called)             ▼
              POST /auth/login
                     │
           ┌─────────┴─────────┐
           │                   │
        Failure             Success
      (401/403/500)            │
           │                   ▼
           ▼           Save crm_token +
    Show Error         crm_user To
    Banner             localStorage
    (clears when             │
     user types)             ▼
                      Resolve Role
                             │
                             ▼
                      Redirect To
                      Role Dashboard
```

## 1.3 Route Guard Flow (every protected route)

```
User Navigates To Route
     │
     ▼
Auth Guard: token exists?
     │
    ┌┴────────────────┐
    │                 │
   No                Yes
    │                 │
    ▼                 ▼
Redirect       Role Guard:
/login         route allowed
               for user role?
                      │
            ┌─────────┴─────────┐
            │                   │
           No                  Yes
            │                   │
            ▼                   ▼
     Redirect To          Render Route
     Own Dashboard
     (403 handling)
```

## 1.4 Add Lead Flow

```
Click Add Lead
(Header Button / Dashboard / Lead List)
     │
     ▼
Open Lead Modal
     │
     ▼
Enter Details
(name, country, phone, email, ...)
     │
     ▼
Click Submit
     │
     ▼
Frontend Validation
- Phone OR Email required
- Phone length by country
- Email format
     │
    ┌┴────────────────┐
    │                 │
 Invalid            Valid
    │                 │
    ▼                 ▼
Show Field      Disable Submit
Errors          + Show Loading
                      │
                      ▼
                POST /leads
                      │
           ┌──────────┴──────────┐
           │                     │
        Failure               Success (201)
      (400/403/500)              │
           │                     ▼
           ▼              Show Success Toast
    Show Error                   │
    Message,                     ▼
    Keep Modal            Close Modal
    Open                         │
                                 ▼
                       Lead Appears In List
                       (realtime event OR
                        list refetch)
```

---

# 2. Task Breakdown & Estimates

## Phase 0 — Foundation (before any module)

| ID | Task | Est (h) | Depends On |
|----|------|---------|------------|
| FE-001 | Project setup: scaffold, router, folder structure, lint, env config | 2 | — |
| FE-002 | API client: base fetch/axios wrapper, JWT header injection, global 401 handler | 2 | FE-001 |
| FE-003 | Shared UI kit: Button, Input, Modal, Toast, Error Banner, Loader | 4 | FE-001 |
| FE-004 | Auth store: state management + localStorage sync (crm_token, crm_user) | 2 | FE-001 |

Phase 0 subtotal: **10 h**

## Phase 1 — Authentication Module

| ID | Task | Est (h) | Depends On |
|----|------|---------|------------|
| FE-101 | Login page UI: logo, layout, responsive, password visibility toggle | 3 | FE-003 |
| FE-102 | Client-side validation: required fields, email format, max 255, trim | 1.5 | FE-101 |
| FE-103 | Login API integration: loading state, error banner, error clears on typing | 2 | FE-002, FE-102 |
| FE-104 | Role-based redirect after login (5 role dashboards) | 1.5 | FE-103 |
| FE-105 | Auth route guard: unauthenticated users → /login | 2 | FE-004 |
| FE-106 | RBAC route guard: cross-role dashboard access → redirect to own dashboard | 2 | FE-105 |
| FE-107 | Session restore on refresh / new tab (bootstrap + GET /auth/me) | 2 | FE-004 |
| FE-108 | Token expiry handling: any 401 → clear session → redirect /login | 1.5 | FE-002 |
| FE-109 | Logout: clear storage, reset state, redirect /login | 1 | FE-004 |
| FE-110 | Edge cases: double-click submit, browser offline, corrupted localStorage | 2 | FE-103 |
| FE-111 | QA checklist pass + bug fixes (auth module) | 2 | FE-101…110 |

Phase 1 subtotal: **20.5 h**

## Phase 2 — Lead Creation

| ID | Task | Est (h) | Depends On |
|----|------|---------|------------|
| FE-201 | Global Add Lead button in header + entry points on dashboard and lead list | 1.5 | FE-003 |
| FE-202 | Add Lead modal UI: form fields, layout, close/cancel without saving | 3 | FE-003 |
| FE-203 | Country selector + phone input with country-based length validation | 3 | FE-202 |
| FE-204 | Phone-OR-email mandatory rule + email format validation | 1.5 | FE-202 |
| FE-205 | Create Lead API integration: submit, loading state, prevent duplicate submit | 2 | FE-002, FE-204 |
| FE-206 | Success flow: toast, close modal, reset form | 1 | FE-205 |
| FE-207 | Realtime subscription: new lead appears in list instantly, reconnect handling | 3 | FE-205 |
| FE-208 | Error handling: 400 / 403 / 500, network timeout, user-friendly messages | 1.5 | FE-205 |
| FE-209 | Edge cases + QA checklist pass (lead creation) | 2 | FE-201…208 |

Phase 2 subtotal: **18.5 h**

---

# 3. Summary & Timeline

| Phase | Scope | Hours | Working Days (8h) |
|-------|-------|-------|-------------------|
| Phase 0 | Foundation | 10 | 1.3 |
| Phase 1 | Authentication | 20.5 | 2.6 |
| Phase 2 | Lead Creation | 18.5 | 2.3 |
| — | Buffer (15% — reviews, rework, integration issues) | 7.5 | 0.9 |
| **Total** | **Auth + Lead Creation MVP** | **56.5** | **~7 days** |

Notes on the estimate:

- The buffer covers code review feedback, API contract changes,
  and integration debugging with the backend.
- FE-207 (realtime) is the riskiest task — the estimate assumes the
  backend realtime channel (e.g. Supabase / WebSocket / SSE) is
  already decided and documented. If not, flag it early.
- Phases 1 and 2 can slightly overlap once Phase 0 is done, but a
  single developer should finish auth guards before lead screens,
  since every lead screen sits behind them.

---

# 4. Tracking

Track each task with this template (copy into your tracker / sheet):

| ID | Task | Est (h) | Actual (h) | Status | Blocker / Notes |
|----|------|---------|------------|--------|-----------------|
| FE-101 | Login page UI | 3 | | Not Started | |

Status values:

```
Not Started → In Progress → In Review → Done
                  │
                  ▼
              Blocked (note the reason + who unblocks it)
```

Working agreement (suggested):

- Update Status + Actual hours daily (end of day).
- A task stays "In Progress" max 2 days — if longer, split it or
  mark it Blocked with a reason.
- Estimate vs Actual variance > 50% → mention it in standup so
  future estimates improve.
- Definition of Done: works in the browser, passes the story's QA
  checklist items, reviewed, merged.
