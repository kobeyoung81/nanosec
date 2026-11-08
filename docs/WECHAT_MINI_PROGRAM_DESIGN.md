# WeChat Mini Program Design Document

**Version**: 2.1  
**Date**: 2026-08-15  
**Status**: Current

---

## 1. Summary

This document defines the **full product, frontend, and backend design** for the myriadmind WeChat mini program.

> **Current implementation status (2026-08-15):** The `nanoui` submodule provides the
> miniapp (Home / Agent / Me / Subscription tabs) and a real Go backend (`nanoui/backend`):
> WeChat login proxy to `nanoauth` (`POST /api/auth/wechat/login`), account/bootstrap
> endpoints, subscription plans and order creation (`subscription_plans` / 
> `subscription_orders`, migrations 020–021), and per-binding preferences
> (migration 022). WeChat Pay prepay is currently stubbed (placeholder `prepay_id`).


The mini program is the end-user self-service product for:

1. native account onboarding and login
2. account binding and identity management
3. subscription purchase and renewal with WeChat Pay
4. per-binding agent visibility and safe configuration
5. future usage, activity, and support workflows

This is **not** the main general-purpose chat interface in MVP. Its primary role is account center, subscription center, and binding-owned agent management.

This document is aligned with `docs/ACCOUNT_MANAGEMENT_DESIGN.md`, which is the source of truth for identity, binding, entitlement, runtime ownership, and runtime transfer semantics.

---

## 2. Product Scope

### 2.1 Goals

- Provide a first-class WeChat-native account entry point.
- Make subscription state and WeChat Pay flows trustworthy and easy to understand.
- Let users manage the agent that belongs to their current mini-program binding.
- Prepare a clean path for future multi-binding agent views and transfer workflows.
- Define the full frontend and backend shape needed to implement the mini program as a real product.

### 2.2 Non-Goals

- Replacing WeChat KF, WeCom, Feishu, or DingTalk chat surfaces in MVP
- Becoming the only runtime management surface for all bindings on day one
- Full admin operations
- Exposing raw infrastructure data, secrets, queue records, or internal service configs

---

## 3. Core Design Decisions

### 3.1 Identity Model

The mini program uses the native-account model defined in `ACCOUNT_MANAGEMENT_DESIGN.md`.

The key relationships are:

```text
native_account 1 --- N external_account_bindings
external_account_binding 1 --- 0..1 agent_runtime
```

For the mini program:

- the mini program login creates or resolves a **native account**
- it also creates or resolves a **`miniprogram` external binding**
- that binding may own **zero or one** agent runtime
- the native account may own **zero to many** agents through all of its bindings

### 3.2 Runtime Ownership in the Mini Program

The mini program should treat the current logged-in `miniprogram` binding as the primary runtime context for MVP.

That means:

- the Agent tab manages the **agent for the current mini-program binding**
- account pages still show native-account-level information such as tier, billing, and linked identities
- future versions may add a binding switcher or multi-agent overview

### 3.3 Product Repository Decision

The full mini program product should live in a **separate repo named `nanoui`**.

Reasoning:

- the current super-repo should remain focused on shared docs, workspace config, and submodule orchestration
- the mini program has its own frontend and backend lifecycle
- WeChat build tooling, release flow, CI, and product assets should be isolated from the core service repos

Recommended ownership:

```text
nanoui/
  miniapp/        # WeChat mini program frontend
  backend/        # mini program backend / BFF / product API
  docs/           # product-specific docs
  scripts/        # release and developer scripts
```

---

## 4. Recommended Solution Shape

### 4.1 High-Level Architecture

```text
WeChat Mini Program Frontend
        |
        | HTTPS
        v
nanoui backend (BFF + product APIs)
        |
        +--> WeChat login / profile APIs
        +--> WeChat Pay APIs + callback handling
        +--> account + binding data store
        +--> integration with nanobus / nanogateway / nanosec / nanorunner
        +--> future notification + support services
```

### 4.2 Why a Dedicated Backend

The mini program should not call core platform services directly.

The dedicated backend in `nanoui` should:

- verify WeChat identity
- issue app sessions/tokens
- expose stable product APIs for the mini program
- manage payment orders and WeChat Pay callbacks
- orchestrate account, binding, and runtime lifecycle
- translate safe product settings into backend-facing agent preferences

### 4.3 Frontend / Backend Boundary

| Concern | Frontend | Backend |
|---|---|---|
| WeChat login UX | yes | no |
| login credential exchange | no | yes |
| account and binding resolution | no | yes |
| payment UI | yes | no |
| payment order creation and callback verification | no | yes |
| agent preference forms | yes | no |
| validation, persistence, policy enforcement | no | yes |
| account, entitlement, runtime orchestration | no | yes |

---

## 5. Information Architecture

Use a simple three-tab structure:

1. **Home**
2. **Agent**
3. **Me**

### 5.1 Home

Purpose:

- show current account and subscription state
- show the status of the current mini-program binding's agent
- provide the quickest path to pay, renew, reactivate, or configure

Modules:

- account hero card
- subscription summary
- current binding agent status
- upgrade / renew CTA
- notices and support entry
- future usage teaser

### 5.2 Agent

Purpose:

- manage the agent owned by the current mini-program binding
- show clear runtime state
- expose safe configuration only

States:

- no runtime yet
- provisioning
- active
- suspended
- transfer pending or unavailable later

Modules:

- current binding card
- agent status card
- safe settings form
- future activity and usage entry

### 5.3 Me

Purpose:

- account center
- billing center
- identity and binding center

Modules:

- native account profile
- linked bindings
- current tier and subscription
- payment history
- auto-renew management
- help / FAQ / support

---

## 6. User Management and Binding Design

### 6.1 Current Platform Fit

The current platform resolves identities through:

```text
(channel, sender_id) -> user_id
```

The mini program should extend this model with:

- `channel = "miniprogram"`
- `provider = "wechat"`
- `sender_id = openid`
- optional `union_id`

### 6.2 First Login Flow

1. User opens mini program.
2. Frontend calls WeChat login and gets `code`.
3. `nanoui` backend exchanges `code` for `openid` and optional `unionid`.
4. Backend resolves or creates the `miniprogram` binding.
5. If the binding is new:
   - create native account if needed
   - create `miniprogram` binding
   - initialize entitlement as `trial` or `free`
   - initialize binding-owned runtime as `none` or `active` by policy
6. Backend creates an app session and returns account summary.

### 6.3 Binding Rules

1. One native account can bind multiple external identities.
2. One external identity can bind to only one native account at a time.
3. One binding can own zero or one active agent runtime.
4. The mini-program binding can later participate in runtime transfer workflows under the same native account.

### 6.4 What the Mini Program Should Show

The mini program should distinguish:

- **account-level state**: tier, billing, profile, shared defaults
- **binding-level state**: current mini-program binding status, binding-owned runtime status, binding-specific preferences

This avoids mixing account management with agent runtime management.

---

## 7. Frontend Design

### 7.1 Frontend Technology Direction

Inside `nanoui/miniapp/`:

- native WeChat mini program pages and components
- localized copy, primarily `zh-CN`
- product API client for `nanoui` backend
- lightweight state management around session, account summary, and binding runtime state

### 7.2 Frontend Page Map

| Page | Purpose |
|---|---|
| Launch / Login | WeChat login, consent, bootstrap |
| Home | account + subscription + current binding agent summary |
| Tier Detail / Checkout | compare plans and pay |
| Agent | current binding agent settings and status |
| Agent Runtime State | no-runtime / suspended / provisioning guidance |
| Me | profile, bindings, support, billing |
| Payment History | orders and invoices later |
| Binding Center | linked identities and future transfer actions |

### 7.3 Frontend State Model

Recommended client-side slices:

- session
- account summary
- current binding summary
- entitlement summary
- runtime summary
- payment state
- notices

### 7.4 Home UX

Home should show:

- native account display name
- current tier badge
- entitlement status
- next renewal date
- current binding runtime status
- one primary CTA based on status

Primary CTA examples:

| State | CTA |
|---|---|
| trial active, runtime none | Activate Agent |
| active paid tier | Manage Agent |
| renewal failed | Fix Payment |
| runtime suspended | Reactivate Agent |

### 7.5 Agent UX

The Agent tab should make it obvious that the user is managing:

> the agent for this mini-program account binding

Safe editable settings:

| Category | Fields |
|---|---|
| Model Preference | balanced / quality / speed |
| Response Style | concise / balanced / detailed |
| Language | zh-CN / en-US later |
| Tool Preferences | web access label, confirmation mode |
| Session Behavior | quiet hours, memory mode label |

Do not expose:

- API keys
- raw workspace paths
- shell policy internals
- container image, network, or runner internals

### 7.6 Me UX

Me should include:

- profile summary
- masked account ID
- linked bindings
- current subscription
- auto-renew control
- payment history
- support entry

Binding Center should later show:

- binding type
- binding status
- whether that binding owns an active runtime
- future transfer eligibility

---

## 8. Backend Design

### 8.1 Backend Responsibilities

Inside `nanoui/backend/`, the backend should provide:

1. authentication and session management
2. account and binding APIs
3. payment APIs and callbacks
4. entitlement APIs
5. binding runtime APIs
6. agent preference APIs
7. future notification, usage, and support APIs

### 8.2 Recommended Backend Modules

| Module | Responsibility |
|---|---|
| auth | WeChat login exchange, session issuance, token verification |
| account | native account summary and profile |
| binding | linked identities, binding state, future transfer operations |
| entitlement | plans, subscriptions, renewals, status |
| payment | order creation, callback verification, reconciliation |
| runtime | binding runtime status, activation, suspension, transfer orchestration |
| preferences | safe agent preference read/write |
| notifications | in-app notices and future WeChat notifications |

### 8.3 Backend Integration Responsibilities

The backend should integrate with:

- WeChat auth APIs
- WeChat Pay APIs
- `nanobus` for identity and lifecycle coordination
- future runtime orchestration paths touching `nanosec` and `nanorunner`
- account and billing storage

### 8.4 BFF vs Domain Logic

Keep the public API boundary product-focused.

Frontend-facing backend APIs should speak in terms like:

- account
- binding
- agent
- tier
- payment
- subscription

They should not expose raw bus or runner concepts.

---

## 9. Backend APIs

Recommended frontend-facing API groups:

### 9.1 Auth

- `POST /api/miniapp/auth/login`
- `POST /api/miniapp/auth/refresh`
- `POST /api/miniapp/auth/logout`

### 9.2 Account

- `GET /api/miniapp/account`
- `PATCH /api/miniapp/account/profile`
- `GET /api/miniapp/account/bindings`

### 9.3 Entitlement and Billing

- `GET /api/miniapp/plans`
- `GET /api/miniapp/subscription`
- `POST /api/miniapp/orders`
- `POST /api/miniapp/payments/wechat/notify`
- `GET /api/miniapp/orders`

### 9.4 Binding Runtime and Agent

- `GET /api/miniapp/bindings/current`
- `GET /api/miniapp/bindings/current/runtime`
- `POST /api/miniapp/bindings/current/runtime/activate`
- `POST /api/miniapp/bindings/current/runtime/suspend`
- `GET /api/miniapp/bindings/current/preferences`
- `PUT /api/miniapp/bindings/current/preferences`

### 9.5 Future Binding Transfer APIs

- `POST /api/miniapp/bindings/{bindingId}/runtime-transfer/request`
- `POST /api/miniapp/bindings/{bindingId}/runtime-transfer/confirm`

These are future-facing and should be gated until transfer behavior is implemented.

---

## 10. Data Model

This design should align with `ACCOUNT_MANAGEMENT_DESIGN.md`.

### 10.1 Core Tables

Use or evolve:

- `users` as native accounts
- `user_channels` as external bindings
- `account_entitlements`
- `binding_runtimes`

### 10.2 Mini Program Product Tables

Recommended additions:

```sql
CREATE TABLE subscription_plans (
    plan_id              VARCHAR(64) PRIMARY KEY,
    tier                 ENUM('trial','free','pro','ultra') NOT NULL,
    billing_period       VARCHAR(32) NOT NULL,
    amount_fen           INT NOT NULL,
    auto_renew_capable   TINYINT(1) DEFAULT 1,
    status               ENUM('active','inactive') DEFAULT 'active'
);

CREATE TABLE subscription_orders (
    order_id             VARCHAR(64) PRIMARY KEY,
    user_id              VARCHAR(255) NOT NULL,
    plan_id              VARCHAR(64) NOT NULL,
    binding_id           BIGINT NULL,
    amount_fen           INT NOT NULL,
    status               ENUM('created','paid','failed','canceled','refunded') NOT NULL,
    wechat_prepay_id     VARCHAR(128),
    created_at           TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at           TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE binding_agent_preferences (
    binding_id           BIGINT PRIMARY KEY,
    preferences_json     JSON NOT NULL,
    updated_at           TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
```

### 10.3 Why Preferences Should Be Binding-Scoped

Because runtime ownership is binding-scoped, mini-program-visible agent preferences should default to being binding-scoped too.

Account-level defaults can still exist separately.

---

## 11. Payment and Subscription Design

### 11.1 Payment Flow

1. User selects plan.
2. Frontend calls order creation API.
3. Backend creates order and WeChat prepay payload.
4. Frontend invokes WeChat Pay.
5. Backend verifies callback.
6. Backend updates entitlement.
7. Backend updates runtime policy when needed.
8. Frontend shows success and refreshed account state.

### 11.2 Entitlement Effects

After verified payment:

1. mark order paid
2. update `account_entitlements`
3. update account-facing tier summary
4. update eligible binding runtime policy
5. emit entitlement-change events

### 11.3 Runtime Activation Policy

Do not assume payment always means instant runtime creation for every binding.

Recommended policy:

- entitlement changes happen at the native-account level
- runtime activation decisions happen at the binding level
- the current mini-program binding may be auto-activated or user-activated depending on product rules

---

## 12. Binding Runtime Design

### 12.1 MVP Binding Runtime Scope

For MVP, the mini program primarily manages:

- the current logged-in `miniprogram` binding runtime

### 12.2 Supported Runtime States

- none
- provisioning
- active
- suspended
- failed
- transfer-pending later

### 12.3 Runtime Transfer Compatibility

The mini program design must remain compatible with future runtime transfer between bindings under the same native account.

Frontend implications:

- binding center should later show transfer eligibility
- agent pages should tolerate the runtime moving away from the current binding

Backend implications:

- runtime ownership must stay keyed by `binding_id`
- transfer APIs and events should remain binding-scoped

---

## 13. Notifications and Messaging

Recommended product notifications:

- payment success
- payment failed
- renewal reminder
- renewal failed
- entitlement changed
- binding runtime activated
- binding runtime suspended
- settings saved

Delivery:

- in-app first
- optional WeChat service notifications later

---

## 14. Trust, Safety, and Privacy

- WeChat Pay pages must clearly explain recurring billing and cancellation.
- Sensitive account and payment data should be masked.
- Binding and transfer actions should be auditable.
- Agent settings must expose only safe, reversible, product-level controls.
- If policy overrides a user preference, the UI should explain that clearly.

---

## 15. Delivery Plan

### 15.1 Repository Plan

Create a dedicated repository:

- `nanoui` — full mini program product repo

Recommended responsibilities:

- mini program frontend
- product backend / BFF
- product CI, release, and environment config
- product-specific docs

### 15.2 MVP Scope

- WeChat login
- native account creation / binding resolution
- Home / Agent / Me tabs
- current tier and subscription state
- WeChat Pay checkout
- current mini-program binding runtime status
- safe binding-scoped agent preferences
- linked bindings view

### 15.3 Phase 2

- richer binding center
- runtime activation and suspension flows
- usage and activity summaries
- more granular preference controls

### 15.4 Phase 3

- runtime transfer workflows between bindings
- multi-binding agent overview
- support and dispute flows
- richer account center and usage dashboards

---

## 16. Final Recommendation

Rename the current UI-focused doc to a full **WeChat Mini Program Design Document**, and treat the mini program as a full product spanning:

1. a dedicated frontend in `nanoui/miniapp`
2. a dedicated backend in `nanoui/backend`
3. native account, binding, entitlement, and runtime orchestration aligned with `ACCOUNT_MANAGEMENT_DESIGN.md`

The MVP should make four things excellent:

- login and account bootstrap
- subscription trust and payment clarity
- current binding agent management
- a clean path toward multi-binding runtime management in later phases
