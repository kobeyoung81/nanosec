# Security policy

## Supported versions

NanoSec ships from `master`. Security fixes land there and in the most recent
tagged release; older tags are not patched. If you run a fork, port the fix.

## Reporting a vulnerability

**Do not open a public issue, a discussion, or a pull request that describes the
problem.** A public report puts every deployment at risk until a fix ships.

Use GitHub's private vulnerability reporting on this repository
(`Security` → `Report a vulnerability`). If that is unavailable — the Gitee mirror
has no such feature — contact the repository owner privately through the address on
their Gitee profile, and say which repository and which surface is affected.

A useful report contains:

- the affected component (bus, gateway, agent container, console, admin, auth,
  provisioner, workspace, work library) and the version or commit;
- how it is reached — a channel, an HTTP surface, a WebSocket, or local access to
  the host;
- what an attacker gains: data of another account, code execution inside a
  container, host access, or a denial of service;
- a reproduction, if you have one, with secrets redacted.

## What to expect

- We acknowledge within **three working days**.
- We confirm or reject the finding within **ten working days**, and tell you the
  planned fix window.
- We credit you in the release notes unless you ask us not to.
- Please give us **90 days** before publishing, or less if a fix ships earlier and
  we agree on a date.

## Scope

In scope:

- authentication and authorization bypasses, including cross-account reads in the
  console, the work library, or the admin API;
- token handling: the shared internal token, JWTs and JWKS, refresh tickets, the
  work library's preview cookie;
- container escapes and anything that lets an agent container reach another user's
  data or the host beyond its intended mounts;
- injection through a channel adapter (message content, media, callback payloads);
- secrets exposed in logs, error bodies, or generated documents.

Out of scope:

- the operator's own misconfiguration (a shared token in a public repository, an
  unauthenticated MongoDB exposed to the internet, a model API key in
  `admin_config` readable by an administrator);
- vulnerabilities in a model provider or in third-party LLM output;
- denial of service through ordinary resource exhaustion without a specific
  amplification;
- findings that require an already-compromised administrator account.

## Handling secrets in a report

Redact tokens, database URIs, API keys and customer data as `***`. If the report
cannot be understood without one, say so and we will arrange a private channel.
