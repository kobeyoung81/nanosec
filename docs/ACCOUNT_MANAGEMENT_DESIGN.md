# Account Management Design Document

**Version**: 1.3  
**Date**: 2026-08-15  
**Status**: Current

---

## 1. Summary

This document defines a **native account model** for myriadmind.

The core design is:

1. Every person has one **native account** inside myriadmind.
2. That native account can bind to multiple **external accounts** such as `wechat`, `wechatkf`, `wecom`, `feishu`, `dingtalk`, and `miniprogram`.
3. Each **external account binding** can own its own nanosec agent runtime.
4. A native account may legitimately have **zero to many** agents through its external bindings, while each external binding may have **zero or one** active agent runtime.

This supports:

- WeChat mini-program first login with automatic account creation
- cross-channel identity binding
- future account center UX
- trial-tier users whose account exists while one or more binding-owned runtimes are suspended or not yet provisioned

> **Current implementation status (2026-08-15):** The native account model is realized
> across `nanoauth` (registration, bcrypt passwords, RS256 JWTs, refresh tokens, WeChat
> OAuth login — `users`, `refresh_tokens`, `oauth_providers`, migration 014) and the
> binding model in `nanobus` (`user_channels` with `binding_id` / `binding_status`,
> migration 012). The miniapp consumes accounts via `nanoui/backend` and stores
> per-binding agent preferences (`binding_agent_preferences`, migration 022).

---

## 2. Design Verdict

Your updated idea is valid, and the correct refinement is now:

> The zero-or-one relationship should be between each **external account binding** and its **agent runtime**, while the **native account** owns the set of bindings and therefore zero to many agents overall.

Why:

- one real user may have several external identities
- those identities should converge into one canonical account
- product entitlements and billing are still account-level concerns
- agent runtime ownership can now vary by external binding
- trial expiry or suspension should disable one or more binding-owned runtimes without destroying account bindings

So the recommended model is:

```text
native_account 1 --- N external_accounts
external_account 1 --- 0..1 agent_runtime
native_account 1 --- 0..N agent_runtimes (through bindings)
```

---

## 3. Current Platform State

The current platform already provides the first half of this design.

### 3.1 Existing Identity Model

The bus currently resolves identities as:

```text
(channel, sender_id) -> user_id
```

This is implemented through:

- `users`
- `user_channels`
- `nanobus/internal/store/user.go -> ResolveUser()`

### 3.2 Existing Runtime Ownership Model

The current runtime already assumes:

- `nanosec` runs as `--user=<user_id>`
- `nanorunner` provisions containers per `user_id`
- portal user views are keyed by `user_id`

So, in practice, current `user_id` already behaves like the system's native account ID.

### 3.3 Existing Gap

The current system does **not** yet clearly separate:

- native account identity
- external account bindings
- entitlement/tier lifecycle
- runtime lifecycle
- binding-scoped runtime ownership

It also auto-creates a container request during first identity resolution, which is too eager for trial and suspended-account scenarios.

---

## 4. Terminology

### 4.1 Native Account

The canonical user record inside myriadmind.

Owns:

- account identity
- tier / entitlement
- billing relationship
- profile and preferences
- shared profile and policy defaults
- zero-to-many binding-owned agents

### 4.2 External Account

A login or channel identity from an external platform.

Examples:

- `wechat`
- `miniprogram`
- `wechatkf`
- `wecom`
- `feishu`
- `dingtalk`

An external account is a **binding**, not the root identity.

### 4.3 Binding-Owned Agent Runtime

The nanosec agent/container lifecycle for one external account binding.

States can include:

- not provisioned
- provisioning
- active
- suspended
- terminated

### 4.4 Tier / Entitlement

The product plan granted to the native account, such as:

- `trial`
- `free`
- `pro`
- `ultra`

Tier should not be used as the only proxy for runtime state.

---

## 5. Recommended Domain Model

### 5.1 Canonical Relationship Model

```text
native_account
  ├── external_account(miniprogram, openid) -> agent_runtime(optional)
  ├── external_account(wechatkf, external_user_id) -> agent_runtime(optional)
  ├── external_account(wecom, user_id/openid) -> agent_runtime(optional)
  ├── external_account(feishu, open_id/user_id) -> agent_runtime(optional)
  ├── external_account(dingtalk, union_id/open_id) -> agent_runtime(optional)
  └── ...
```

### 5.2 Binding Invariants

1. One native account can bind many external accounts.
2. One external account can bind to only one native account at a time.
3. One external account binding can have zero or one active agent runtime.
4. One native account can have zero to many active agents across its bindings.
5. Runtime suspension must not require deleting account or binding records.
6. Billing and core account identity remain on the native account even if all binding-owned runtimes are suspended.

### 5.3 Why Keep Native Account Above External Accounts

- avoids duplicate users across channels
- allows a single subscription across several login surfaces
- allows shared account defaults with optional binding-specific agent behavior
- makes account suspension reversible
- matches the existing `users`-keyed runtime model

---

## 6. Recommended Data Model

### 6.1 Design Choice

The lowest-risk evolution path is:

1. Keep `users.id` as the native account ID.
2. Keep `user_channels` as the binding table, but evolve it into a richer external-account model.
3. Add explicit tables for entitlement and binding-owned runtime lifecycle instead of overloading `users.status`.

This avoids a disruptive account-ID migration while still making the domain model explicit.

### 6.2 `users` as Native Accounts

Interpret `users` as the native account table.

Recommended evolution:

```sql
ALTER TABLE users
    MODIFY COLUMN status ENUM('pending','active','suspended','disabled','deleted') NOT NULL DEFAULT 'pending',
    MODIFY COLUMN level  ENUM('trial','free','pro','ultra') NOT NULL DEFAULT 'trial',
    ADD COLUMN display_name VARCHAR(255) NULL,
    ADD COLUMN avatar_url VARCHAR(1024) NULL,
    ADD COLUMN default_language VARCHAR(32) NULL,
    ADD COLUMN trial_ends_at TIMESTAMP NULL,
    ADD COLUMN suspended_at TIMESTAMP NULL,
    ADD COLUMN suspension_reason VARCHAR(255) NULL;
```

Notes:

- `level` remains the product-facing tier
- `status` remains the account status
- `trial` becomes a valid account entitlement
- binding-owned runtime state still belongs elsewhere

### 6.3 Evolve `user_channels` into External Accounts

Current table:

```sql
user_channels(user_id, channel, sender_id, enabled, created_at)
```

Recommended evolution:

```sql
ALTER TABLE user_channels
    ADD COLUMN provider VARCHAR(64) NULL AFTER user_id,
    ADD COLUMN provider_subject_type VARCHAR(64) NULL AFTER sender_id,
    ADD COLUMN union_id VARCHAR(255) NULL AFTER sender_id,
    ADD COLUMN binding_status ENUM('active','disabled','revoked') NOT NULL DEFAULT 'active' AFTER enabled,
    ADD COLUMN is_primary_login BOOLEAN NOT NULL DEFAULT FALSE AFTER binding_status,
    ADD COLUMN profile_json JSON NULL AFTER is_primary_login,
    ADD COLUMN last_login_at TIMESTAMP NULL AFTER profile_json,
    ADD COLUMN verified_at TIMESTAMP NULL AFTER last_login_at;
```

Recommended semantics:

| Field | Meaning |
|---|---|
| `channel` | delivery or login surface used by current services |
| `provider` | canonical provider family such as `wechat`, `wecom`, `feishu`, `dingtalk` |
| `sender_id` | stable provider subject used for bus resolution |
| `union_id` | cross-app identity when the provider supports it |
| `binding_status` | lifecycle of the binding |
| `profile_json` | masked provider metadata such as nickname, avatar, tenant hints |

For compatibility, `channel` can continue driving current routing while `provider` clarifies account semantics.

### 6.4 Add Account Entitlement Table

```sql
CREATE TABLE account_entitlements (
    user_id              VARCHAR(255) PRIMARY KEY,
    tier                 ENUM('trial','free','pro','ultra') NOT NULL,
    status               ENUM('active','grace','expired','canceled') NOT NULL,
    auto_renew           TINYINT(1) NOT NULL DEFAULT 0,
    current_period_start TIMESTAMP NULL,
    current_period_end   TIMESTAMP NULL,
    trial_ends_at        TIMESTAMP NULL,
    source               VARCHAR(64) NOT NULL,   -- "system", "wechatpay", "admin"
    updated_at           TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

This keeps billing/entitlement separate from basic account identity.

### 6.5 Add Binding Runtime Table

```sql
CREATE TABLE binding_runtimes (
    binding_id            BIGINT PRIMARY KEY,
    user_id               VARCHAR(255) NOT NULL,
    desired_state         ENUM('none','active','suspended') NOT NULL DEFAULT 'none',
    current_state         ENUM('none','provisioning','active','suspended','failed','terminated') NOT NULL DEFAULT 'none',
    runtime_tier          ENUM('trial','free','pro','ultra') NULL,
    suspension_reason     VARCHAR(255) NULL,
    suspended_until       TIMESTAMP NULL,
    active_container_id   VARCHAR(255) NULL,
    active_agent_id       VARCHAR(255) NULL,
    last_transition_at    TIMESTAMP NULL,
    updated_at            TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
```

This is the critical separation that enables:

- account exists, all binding runtimes absent
- account active, one binding runtime suspended while another stays active
- account active, runtimes provisioned per binding later

Because the current `user_channels` schema has no stable surrogate key, the recommended migration is to add one first:

```sql
ALTER TABLE user_channels
    ADD COLUMN binding_id BIGINT NOT NULL AUTO_INCREMENT UNIQUE FIRST;
```

Then use `binding_id` as the runtime ownership anchor.

### 6.6 Keep `container_requests`, but Change the Trigger

Do **not** create a `container_requests` row immediately on every new identity.

Instead:

1. create native account
2. create external binding
3. evaluate entitlement + binding runtime desired state
4. create runtime/container request only when that binding's desired state becomes `active`

---

## 7. WeChat Mini Program Login Design

### 7.1 First Login Flow

Recommended flow:

1. Mini program calls WeChat login and gets `code`.
2. Backend exchanges `code` for `openid` and optional `unionid`.
3. Backend resolves binding on `(channel=miniprogram, sender_id=openid)`.
4. If binding exists:
   - return the existing native account
   - update login metadata
5. If binding does not exist:
   - create native account
   - create `miniprogram` external binding
   - initialize entitlement as `trial` or `free`, depending on product decision
   - initialize the mini-program binding runtime as `none` or `active` based on policy

### 7.2 Recommended Persistence

For mini program:

- `channel = "miniprogram"`
- `provider = "wechat"`
- `sender_id = openid`
- `union_id = unionid` when available

### 7.3 Why `unionid` Matters

`openid` is app-scoped in the WeChat ecosystem. `unionid` is useful for future linking across:

- mini program
- official account
- other WeChat surfaces

So the design should store `unionid` when available, but continue using `sender_id` for current bus resolution compatibility.

### 7.4 Auto-Binding Rule

Default recommendation:

- auto-create a native account on first mini-program login
- do **not** auto-merge with another account unless there is a trusted and deterministic match rule

Safer merge options later:

- verified SMS/email confirmation
- in-app authenticated binding flow
- operator-assisted merge

---

## 8. Trial Tier Design

### 8.1 Product Goal

You want a tier below free where:

- the user can have a native account
- the user can log in
- the account can bind to external identities
- one or more nanosec runtimes can be suspended after a certain period

This fits the proposed design well.

### 8.2 Recommended Representation

Use:

- `account_entitlements.tier = 'trial'`
- `binding_runtimes.current_state = 'none'` or `'suspended'` after expiry

This is better than forcing everything into `users.status`.

### 8.3 Trial Lifecycle

```text
account created
  -> trial active
  -> one or more binding runtimes optionally provisioned
  -> trial expires
  -> entitlement becomes expired or free-by-policy
  -> one or more binding desired states become suspended/none
  -> bindings remain intact
```

### 8.4 Why This Is Better Than Deleting the Account

- preserves login continuity
- preserves payment history
- preserves linked identities
- preserves future upgrade path
- keeps suspension reversible

---

## 9. Runtime Ownership Rules

### 9.1 Primary Rule

Each external account binding owns zero or one nanosec runtime.

### 9.2 Consequence

If one user binds:

- mini program
- WeChat KF
- WeCom

those channels may each have their own runtime, while still sharing the same native account, billing relationship, and account-level defaults.

### 9.3 Supported States

| Native account | External binding | Runtime |
|---|---|---|
| exists | bound | none |
| exists | bound | provisioning |
| exists | bound | active |
| exists | bound | suspended |
| suspended/deleted | optional | none |

### 9.4 What Not To Do

Do not force all external bindings for an account to share exactly one runtime. That would:

- prevent per-channel agent isolation
- make independent suspension harder
- couple unrelated channel experiences too tightly
- conflict with the requested zero-or-one-per-binding ownership rule

### 9.5 Future Runtime Transfer Support

The design **does support** future runtime transfer from one binding to another binding under the same native account.

Recommended rule:

1. transfer is allowed only between bindings owned by the same native account
2. the source binding runtime must move to `suspended` or `transferring` before handoff completes
3. the target binding must not already own an active runtime unless the operation is an explicit replace/swap flow
4. billing, entitlement, and account identity stay on the native account and do not move

Recommended transfer semantics:

- **logical ownership transfer**: reassign the agent/runtime record from source `binding_id` to target `binding_id`
- **runtime rehydration transfer**: stop the source runtime, create a target runtime, and restore portable state there

The safer default is **runtime rehydration transfer**, not in-place live reassignment.

Portable state that may transfer:

- agent preferences that are binding-scoped
- runtime metadata
- restorable conversation/session state
- resumable task or memory pointers if supported later

State that should remain account-scoped:

- native account identity
- billing and entitlement
- shared account defaults
- audit history

Recommended handoff sequence:

1. validate source and target bindings belong to the same native account
2. block new work on the source binding
3. snapshot portable runtime state
4. mark source runtime as `transferring` or `suspended`
5. create or activate target binding runtime
6. restore portable state onto the target runtime
7. switch routing so new messages for the target binding go to the new runtime
8. mark transfer complete and audit the action

This keeps the current binding-owned runtime model compatible with future transfer workflows without collapsing back to a single account-owned runtime.

---

## 10. Cross-Service Design Impact

### 10.1 nanobus

Required changes:

- keep `(channel, sender_id) -> user_id` resolution
- introduce a first-class `binding_id` in runtime-related flows
- stop treating first resolution as automatic runtime provisioning for every binding unless policy says so
- add account-aware and binding-aware lifecycle transitions
- expose binding metadata and binding runtime state to admin APIs later

Likely changes:

- `ResolveUser()` creates account + binding
- runtime selection/provisioning should key off `binding_id`, not only `user_id`
- a separate policy/service decides whether that binding needs runtime activation

### 10.2 nanogateway

Required changes:

- add `miniprogram` as a supported identity/login surface when that channel is introduced
- keep using `user_id` as the resolved account ID

Minimal impact:

- gateway mostly remains a transport and resolution layer

### 10.3 nanosec

The current runtime anchor is no longer sufficient if you want one agent per binding.

Likely evolution:

- `nanosec` will need to run for a binding-scoped identity such as `--binding=<binding_id>` or equivalent
- session ownership and queue claiming must be able to target the binding-owned runtime

Without that change, the platform cannot reliably run multiple agents under one native account.

### 10.4 nanorunner

Required change:

- provision or suspend runtimes from binding runtime policy, not merely from user creation

Quota mapping can continue to use account tier, but provisioning decisions must be made per binding runtime.

### 10.5 nanoportal

The portal should evolve from showing only:

- user status
- tier
- channels

to also showing:

- native account profile
- linked external accounts
- entitlement status
- per-binding runtime state
- suspension reason

---

## 11. Recommended API and Event Shape

### 11.1 Useful Internal Events

- `account.created`
- `external_account.bound`
- `external_account.unbound`
- `entitlement.changed`
- `binding_runtime.activation.requested`
- `binding_runtime.suspended`
- `binding_runtime.resumed`
- `binding_runtime.transfer_requested`
- `binding_runtime.transfer_completed`
- `binding_runtime.transfer_failed`

### 11.2 Useful Backend Operations

- resolve or create account from external identity
- bind external account to an existing native account
- suspend or resume runtime for a binding
- list external bindings for a native account
- transfer a runtime between bindings under controlled workflows
- transfer or merge bindings under controlled workflows

---

## 12. Migration Strategy

### Phase 1: Clarify Semantics

- declare `users` to be the native account table
- declare `user_channels` to be the external binding table
- add `binding_id` as a stable binding identifier
- add `miniprogram` channel value
- create this account-management design as the source of truth

### Phase 2: Separate Lifecycle

- add entitlement table
- add binding runtime table
- stop auto-creating `container_requests` during every first login unless that binding should be activated

### Phase 3: Channel and Product Integration

- implement mini-program login backend
- implement linked-identity views in portal/app
- implement trial suspension policy

### Phase 4: Safer Cross-Channel Binding

- add merge/bind workflows
- add runtime transfer workflows between bindings of the same native account
- use `unionid` or verified claims where available
- add audit history for binding changes

---

## 13. Final Recommendation

Adopt the following as the target model for myriadmind:

1. **`users.id` is the native account ID.**
2. **`user_channels` evolves into the external-account binding table.**
3. **A native account can bind many external accounts.**
4. **Each external account binding owns zero or one nanosec runtime.**
5. **A native account can therefore own zero to many agents through its bindings.**
6. **Trial-tier users remain valid accounts even when one or more binding runtimes are suspended.**
7. **Mini-program first login should auto-create the native account and bind `openid`, but runtime provisioning should be policy-driven per binding rather than automatic on every first contact.**

This gives you the account model you want without fighting the current architecture, and it aligns naturally with future billing, mini-program, and portal work.
