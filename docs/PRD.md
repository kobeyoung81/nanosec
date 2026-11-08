# Product Requirements Document: Nanosec

**Version**: 2.1
**Date**: 2026-08-15
**Status**: Current

---

## 1. Executive Summary

### 1.1 Vision

Nanosec is an ultra-lightweight, high-performance **multi-user** AI assistant platform written in Go. It features a decoupled multi-service architecture (Gateway, Bus, Agent, Runner, Auth) that enables horizontal scaling and multi-user support while maintaining simplicity and a research-friendly design.

> **Current implementation status (2026-08-15):** The platform has grown into the MyriadMind
> ecosystem — the four-process model is implemented (plus **nanoauth** for authentication,
> **nanoportal** for administration, **nanoui** for the WeChat Mini Program). Runtime is
> provisioned by **nanorunner** across Docker / Swarm / Kubernetes, agents run as a
> multi-agent runtime per user, and the bus exposes WebSocket + REST + SSE. Enterprise
> features (audit log, alert rules, RBAC, rate limiting, subscriptions) are implemented.
> See [ARCHITECTURE.md](./ARCHITECTURE.md) for the current system.

### 1.2 Goals

| Goal | Description |
|------|-------------|
| **Multi-User** | Support multiple users, each with their own agent instance and sessions |
| **Decoupled Architecture** | Four-process model (Gateway, Bus, Agent, Runner) for scalability |
| **Performance** | Startup time <100ms, memory <50MB idle, minimal message latency overhead |
| **Simplicity** | Maintain <5,000 lines of core code, preserving research-friendly architecture |
| **Distribution** | Four static binaries (`nanobus`, `nanogateway`, `nanosec`, `nanorunner`) with isolated dependencies |
| **Feature Parity** | Support core features from Python nanobot (channels, providers, tools) |
| **Go Idiomacy** | Follow Go best practices, patterns, and conventions |

### 1.3 Non-Goals

| Non-Goal | Rationale |
|----------|-----------|
| Backward compatibility with Python config | Fresh start allows cleaner design |
| Plugin hot-reloading | Compile-time registration is sufficient |
| GUI interface | CLI-first design philosophy |
| Feature parity on day one | Phased delivery over 12 weeks |

---

## 2. Background

### 2.1 Current Python Implementation Analysis

The existing nanobot is an ultra-lightweight (~3,400 LOC) personal AI assistant with:

| Component | Description | LOC (approx) |
|-----------|-------------|--------------|
| Agent Loop | LLM ↔ tool execution cycle | 300 |
| Message Bus | Event-driven message routing | 150 |
| Channels | Telegram, Discord, WhatsApp, Feishu | 800 |
| Providers | 11+ LLM providers via registry | 400 |
| Tools | Shell, Filesystem, Web, Message, Cron, Spawn | 600 |
| Session | Conversation persistence | 200 |
| Config | JSON-based configuration | 250 |
| CLI | Command-line interface | 300 |
| Other | Utils, skills, heartbeat | 400 |

**Key Architectural Patterns:**
- Async/await with `asyncio` for concurrency
- Abstract Base Classes (ABC) for interfaces
- Pydantic for configuration validation
- LiteLLM for unified LLM access
- Event-driven message bus with typed queues

### 2.2 Motivation for Go Rewrite

| Aspect | Python | Go | Benefit |
|--------|--------|-----|---------|
| **Concurrency** | asyncio (cooperative) | Goroutines (preemptive) | True parallelism, simpler mental model |
| **Distribution** | Requires Python runtime | Single static binary | Zero dependencies, easy deployment |
| **Memory** | ~50-100MB runtime | ~10-30MB runtime | 3-5x improvement |
| **Startup** | 500ms-1s (imports) | <100ms | Near-instant cold starts |
| **Type Safety** | Runtime (mypy optional) | Compile-time | Catch errors before deployment |
| **Error Handling** | Exceptions (hidden flow) | Explicit returns | Clear error propagation |

---

## 3. Functional Requirements

### FR-1: Agent Loop

The core message processing pipeline that orchestrates LLM interactions and tool execution.

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1.1 | Process inbound messages from all channels | P0 |
| FR-1.2 | Build context with conversation history and system prompts | P0 |
| FR-1.3 | Execute LLM chat completions with tool definitions | P0 |
| FR-1.4 | Parse and execute tool calls from LLM responses | P0 |
| FR-1.5 | Loop until LLM returns final text response (max 20 iterations) | P0 |
| FR-1.6 | Route responses back through message bus | P0 |
| FR-1.7 | Support configurable model selection per session | P1 |
| FR-1.8 | Handle streaming responses | P2 |

### FR-2: Gateway Service

The gateway handles platform adapters and user identity resolution.

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-2.1 | **CLI**: Interactive stdin/stdout for development and testing | P0 |
| FR-2.2 | **WeCom**: Enterprise WeChat integration via official API | P1 |
| FR-2.3 | **Feishu**: WebSocket long connection | P2 |
| FR-2.4 | **Feishu**: Rich card messages with markdown | P2 |
| FR-2.5 | Resolve user identity via bus: `(channel, sender_id) → user_id` | P0 |
| FR-2.6 | Graceful reconnection on connection loss | P1 |
| FR-2.7 | Post inbound messages to bus with user_id | P0 |
| FR-2.8 | Poll outbound messages from bus per channel | P0 |
| FR-2.9 | **WeChat KF**: Customer Service polling adapter | P1 |
| FR-2.10 | Send ack text message on inbound receipt (configurable) | P1 |
| FR-2.11 | Route media attachments (`[]MediaItem`) in inbound/outbound messages | P1 |

### FR-3: Bus Service

Centralized message routing and user management with MySQL backend.

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-3.1 | WebSocket server for gateway and agent connections | P0 |
| FR-3.2 | User registry: store users and their channel identities | P0 |
| FR-3.3 | Per-user inbound message queues | P0 |
| FR-3.4 | Per-user outbound message queues | P0 |
| FR-3.5 | User identity resolution API for gateway | P0 |
| FR-3.6 | MySQL storage for queues and user registry | P0 |
| FR-3.7 | Message claiming to prevent duplicate processing | P0 |
| FR-3.8 | Stateless design for horizontal scaling | P1 |
| FR-3.9 | Auto-onboarding: create user on first `resolve_user` if not found | P1 |
| FR-3.10 | Container request lifecycle: store, serve, and update `container_requests` | P1 |
| FR-3.11 | User status and level management (`UpdateUserStatus`) | P1 |

### FR-4: Agent Service

Per-user agent that processes messages and executes tools.

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-4.1 | Run as dedicated process per user with `--user` flag | P0 |
| FR-4.2 | Poll inbound messages from bus for assigned user | P0 |
| FR-4.3 | Build context with conversation history and system prompts | P0 |
| FR-4.4 | Execute LLM chat completions with tool definitions | P0 |
| FR-4.5 | Parse and execute tool calls from LLM responses | P0 |
| FR-4.6 | Loop until LLM returns final text response (max 20 iterations) | P0 |
| FR-4.7 | Post outbound responses to bus | P0 |
| FR-4.8 | File-based session storage (JSONL format) | P0 |
| FR-4.9 | Support configurable model selection | P1 |
| FR-4.10 | Handle streaming responses | P2 |

### FR-5: Tools System

Agent capabilities for interacting with the environment.

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-5.1 | **Shell (exec)**: Execute bash commands with timeout | P0 |
| FR-5.2 | **Filesystem**: Read, write, edit, list files | P0 |
| FR-5.3 | **Web Search**: Tavily API integration | P1 |
| FR-5.4 | **Web Fetch**: HTTP GET with content extraction | P1 |
| FR-5.5 | **Message**: Send messages to channels via bus | P0 |
| FR-5.6 | **Cron**: Schedule recurring tasks | P1 |
| FR-5.7 | **Spawn**: Create background subagents | P1 |
| FR-5.8 | Workspace sandboxing (restrict to directory) | P0 |
| FR-5.9 | Tool registry with dynamic registration | P0 |
| FR-5.10 | OpenAI function calling format compatibility | P0 |
| FR-5.11 | **media_download**: Download WeCom media by media_id to local file | P1 |
| FR-5.12 | **media_upload**: Upload local file to WeCom media API, return media_id | P1 |

### FR-6: Provider (MVP)

Single OpenAI-compatible provider for MVP. Most LLM services (OpenAI, DeepSeek, Groq, OpenRouter, local vLLM, etc.) support this API format.

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-6.1 | OpenAI-compatible API client | P0 |
| FR-6.2 | Configurable base URL (for any OpenAI-compatible endpoint) | P0 |
| FR-6.3 | Configurable default model name | P0 |

**Post-MVP**: Native Anthropic API, multi-provider registry, automatic provider detection.

### FR-7: Skills/Plugin System

Extensible capability modules.

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-7.1 | Load skill definitions from markdown files | P2 |
| FR-7.2 | Inject skill prompts into agent context | P2 |
| FR-7.3 | Built-in skills: GitHub, weather, tmux | P2 |

### FR-8: Container Lifecycle (nanorunner)

Per-user Docker container provisioning and management.

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-8.1 | Poll bus for pending `container_requests` | P1 |
| FR-8.2 | Provision Docker container per user with configured image | P1 |
| FR-8.3 | Enforce resource quota based on user tier (level) | P1 |
| FR-8.4 | Dispose containers on request or user level downgrade | P1 |
| FR-8.5 | Post container status updates back to bus | P1 |
| FR-8.6 | Support multiple runner instances behind load balancer | P2 |

---

## 4. Non-Functional Requirements

### NFR-1: Performance

| ID | Requirement | Target | Measurement |
|----|-------------|--------|-------------|
| NFR-1.1 | Binary startup time | <100ms | `time nanosec --version` |
| NFR-1.2 | Idle memory usage | <50MB | RSS after startup |
| NFR-1.3 | Message processing overhead | <10ms | Time from receive to LLM call |
| NFR-1.4 | Concurrent channel handling | 4+ channels | No blocking between channels |
| NFR-1.5 | Binary size | <20MB | Stripped, no CGO |

### NFR-2: Reliability

| ID | Requirement | Description |
|----|-------------|-------------|
| NFR-2.1 | Graceful shutdown | Drain pending messages before exit |
| NFR-2.2 | Error recovery | Continue processing after tool failures |
| NFR-2.3 | Connection resilience | Auto-reconnect channels on disconnect |
| NFR-2.4 | Panic recovery | Recover from panics without crashing |
| NFR-2.5 | Session persistence | Survive restarts with conversation history |

### NFR-3: Security

| ID | Requirement | Description |
|----|-------------|-------------|
| NFR-3.1 | Workspace sandboxing | Restrict file/shell operations to workspace |
| NFR-3.2 | User allowlists | Per-channel authentication |
| NFR-3.3 | Credential protection | No secrets in logs or error messages |
| NFR-3.4 | Command timeout | Prevent runaway shell commands |
| NFR-3.5 | Path traversal prevention | Validate all file paths |

### NFR-4: Maintainability

| ID | Requirement | Description |
|----|-------------|-------------|
| NFR-4.1 | Code size | <5,000 lines of core code |
| NFR-4.2 | Test coverage | >80% line coverage |
| NFR-4.3 | Documentation | GoDoc for all public APIs |
| NFR-4.4 | Linting | Pass golangci-lint with strict config |
| NFR-4.5 | Idiomatic Go | Follow Effective Go guidelines |

---

## 5. User Stories

### US-1: Multi-User Platform Setup
> As an administrator, I want to set up a shared nanosec platform so that multiple users can have their own AI assistants.

**Acceptance Criteria:**
- Start bus service with MySQL connection
- Start gateway service connected to bus
- Register users via bus API
- Link user channel identities (telegram ID, discord ID, etc.)

### US-2: Chat via CLI
> As a developer, I want to chat with my AI assistant via command line so that I can quickly test and validate changes.

**Acceptance Criteria:**
- Interactive stdin/stdout interface
- Responses display immediately
- Commands: /reset, /help
- Easy to use for development and CI testing

### US-3: Chat via WeCom
> As a user, I want to chat with my AI assistant via WeCom (Enterprise WeChat) so that I can get help within my work environment.

**Acceptance Criteria:**
- Bot responds to text messages within 5 seconds
- My conversations are separate from other users
- Works within enterprise security context

### US-4: Execute Shell Commands
> As a developer, I want the assistant to run shell commands so that it can help me with system tasks.

**Acceptance Criteria:**
- Commands execute with configurable timeout
- Output is captured and returned
- Errors are reported clearly
- Workspace restriction prevents dangerous operations

### US-5: Schedule Recurring Tasks
> As a user, I want to schedule daily reminders so that I don't forget important tasks.

**Acceptance Criteria:**
- Natural language scheduling ("every day at 9am")
- Cron expression support
- Tasks persist across restarts
- List, add, remove commands

### US-6: Spawn Background Agents
> As a power user, I want to spawn background tasks so that long-running operations don't block my chat.

**Acceptance Criteria:**
- Subagent runs independently
- Results sent as system messages
- Full tool access for subagents
- Resource limits prevent runaway agents

### US-7: Cross-Channel Conversation
> As a user with multiple chat platforms, I want my assistant to maintain same conversation histories per channel.

**Acceptance Criteria:**
- CLI and WeCom have independent sessions
- Each session stored as separate JSONL file
- Session history survives agent restarts

---

## 6. Success Metrics

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Binary size | <20MB | `ls -lh nanosec` |
| Startup time | <100ms | Benchmark test |
| Memory (idle) | <50MB | `ps aux` RSS |
| Test coverage | >80% | `go test -cover` |
| Core LOC | <5,000 | `cloc internal/` |
| Build time | <30s | `time go build` |
| All P0 features | 100% | Feature checklist |
| All P1 features | 100% | Feature checklist |

---

## 7. Risks and Mitigations

### Risk 1: WeCom API Complexity
**Description**: WeCom (Enterprise WeChat) requires enterprise registration and callback server setup.
**Impact**: Medium - Requires enterprise account
**Probability**: Low
**Mitigation**:
- Use CLI adapter for development/testing
- Provide clear WeCom setup documentation
- Consider go-workwx library for SDK support

### Risk 2: LLM SDK Availability in Go
**Description**: No LiteLLM equivalent in Go for unified LLM access.
**Impact**: Medium - More code for provider support
**Probability**: Certain
**Mitigation**:
- Use `sashabaranov/go-openai` as base (most providers are OpenAI-compatible)
- Build thin adapter layer for non-OpenAI providers
- Declarative registry pattern from Python works well in Go

### Risk 3: Feishu SDK Maturity
**Description**: Feishu/Lark Go SDK may be less mature than Python.
**Impact**: Low - Feishu is P2 priority
**Probability**: Medium
**Mitigation**:
- Use WebSocket directly if SDK insufficient
- Defer Feishu to later phase
- CLI adapter provides fallback for testing

### Risk 4: Feature Creep
**Description**: Temptation to add features beyond Python parity.
**Impact**: Medium - Delays delivery, increases complexity
**Probability**: Medium
**Mitigation**:
- Strict adherence to priority levels
- Phase gates before adding new features
- Code size budget (<5,000 LOC)

### Risk 5: Concurrency Bugs
**Description**: Go's concurrency model differs from Python's asyncio.
**Impact**: High - Race conditions, deadlocks
**Probability**: Medium
**Mitigation**:
- Run tests with `-race` flag
- Use established patterns (errgroup, context)
- Code review focus on concurrency

---

## 8. Dependencies

### External Services
- MySQL database (for bus service)
- LLM APIs (OpenAI, DeepSeek, Groq, etc.)
- Tavily Search API (optional, for web search tool)
- WeCom API (Enterprise WeChat)
- Feishu WebSocket API
- WeChat Customer Service API
- Docker Engine (for nanorunner)

### Go Libraries
| Library | Purpose | License |
|---------|---------|---------|
| `gitee.com/kobeyoung81/nanoprotocol` | Shared WebSocket protocol types + client | - |
| `sashabaranov/go-openai` | OpenAI-compatible LLM client | Apache-2.0 |
| `spf13/cobra` | CLI framework | Apache-2.0 |
| `go-sql-driver/mysql` | MySQL driver | MPL-2.0 |
| `gorilla/websocket` | WebSocket server/client | BSD-2-Clause |
| `xen0n/go-workwx/v2` | WeCom (Enterprise WeChat) | MIT |
| `larksuite/oapi-sdk-go/v3` | Feishu/Lark SDK | MIT |
| `robfig/cron/v3` | Cron expression parsing + scheduling | MIT |
| `google/uuid` | UUID generation | BSD-3-Clause |
| `github.com/docker/docker` | Docker Engine SDK (nanorunner) | Apache-2.0 |
| `stretchr/testify` | Testing utilities | MIT |
| `DATA-DOG/go-sqlmock` | SQL mocking for tests | BSD-3-Clause |

---

## 9. Glossary

| Term | Definition |
|------|------------|
| **Agent** | Per-user AI assistant process that processes messages and executes tools |
| **Auto-Onboarding** | Automatic user creation on first `resolve_user` call from gateway |
| **Bus** | Central message routing service with MySQL backend |
| **ContainerRequest** | A bus-stored request for nanorunner to provision or dispose a Docker container |
| **Gateway** | Service that connects to chat platforms and routes messages to/from bus |
| **Channel** | A chat platform integration (WeCom, WeChat KF, Feishu, CLI, etc.) |
| **MediaItem** | A struct representing a media attachment with type, media_id, and optional URL/name |
| **Provider** | An LLM service (OpenAI, DeepSeek, Groq, etc.) |
| **Runner** | The nanorunner service that provisions/disposes Docker containers per user |
| **Tool** | A capability the agent can invoke (shell, filesystem, media_download, etc.) |
| **Session** | A conversation context with history, stored as JSONL file |
| **Subagent** | A background agent spawned for parallel work |
| **User** | A registered user with linked channel identities |
| **User Registry** | Bus database mapping `(channel, sender_id) → user_id` |
| **Workspace** | The directory where the agent operates |

---

## 10. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-02-08 | Claude | Initial draft |
| 2.0 | 2026-03-17 | Claude | Phase 2: added nanorunner (FR-8), WeChat KF (FR-2.9), ack (FR-2.10), media routing (FR-2.11), auto-onboarding (FR-3.9), container requests (FR-3.10), user status/level (FR-3.11), media tools (FR-5.11/12); updated glossary and dependencies |
| 2.1 | 2026-03-31 | Copilot | Fix dependency table: replaced Viper with bus-based config, gocron with robfig/cron/v3, added nanoprotocol/larksuite/uuid/sqlmock; updated Brave → Tavily for web search |
