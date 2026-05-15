---
name: api-design
description: API design principles and contracts. Use when designing, reviewing, or modifying HTTP/REST APIs. Invoke when defining endpoints, error formats, pagination, or versioning strategy.
---

# API Design Principles

## Core Principle

APIs are contracts. Once a consumer depends on your API, changing it breaks their code. Design for the consumer's mental model, not your internal implementation. Every field name, status code, and URL shape is a promise.

## Resource Naming

- Nouns, not verbs: `GET /users` not `GET /getUsers`. The HTTP method is the verb.
- Plural nouns: `/users`, `/orders`, `/invoices`. Consistent plurality everywhere.
- Hierarchical for relationships: `GET /users/123/orders` — the URL reads like a sentence.
- Lowercase, hyphen-separated: `/order-items` not `/orderItems` or `/order_items`.
- Pick one convention and enforce it across every endpoint. Inconsistency erodes trust.

## HTTP Semantics

Use methods correctly — they have defined semantics:
- **GET** reads. Never mutates state. Always safe to retry.
- **POST** creates a new resource. Not idempotent.
- **PUT** replaces the entire resource. Idempotent.
- **PATCH** partially updates a resource. Send only changed fields.
- **DELETE** removes. Idempotent — deleting twice returns the same result.

Use status codes correctly:
- **201 Created** for successful POST (include Location header).
- **204 No Content** for successful DELETE or PUT with no response body.
- **400 Bad Request** for malformed syntax. **422 Unprocessable Entity** for valid syntax but invalid semantics.
- **404 Not Found** — the resource does not exist. **409 Conflict** — the request conflicts with current state.
- **500 Internal Server Error** — never intentional. If your code returns 500 on purpose, use a 4xx instead.

## Error Contracts

Every error response uses the same structure: `{ "code": "VALIDATION_ERROR", "message": "Email is required", "details": [...] }`. The `code` is machine-readable (clients switch on it). The `message` is human-readable (developers read it). The `details` array holds field-level specifics. Never expose stack traces, SQL queries, or internal paths. Consistent format across all endpoints — the consumer writes one error handler, not one per endpoint.

## Versioning

Pick one strategy and commit: URL path (`/v2/users`), header (`Accept: application/vnd.api.v2+json`), or query param (`?version=2`). URL path is simplest to understand and route. When introducing a breaking change, bump the version. Support the previous version for a documented migration period. Non-breaking additions (new optional fields) do not require a new version.

## Pagination

Always paginate list endpoints — an unbounded list is a production incident waiting to happen. Cursor-based pagination (`?cursor=abc123&limit=20`) is more reliable than offset-based for datasets that change between requests. Include `next_cursor` in the response. Include `total_count` only if computing it is cheap; omit it rather than slow every request.

## Backward Compatibility

- **Safe changes:** adding new fields, adding new endpoints, adding optional parameters.
- **Breaking changes:** removing or renaming fields, changing field types, making optional parameters required, changing URL structure.

When in doubt, it is breaking. Treat your response shape as append-only.

## Idempotency

PUT and DELETE are idempotent by definition. POST is not — two identical POST requests create two resources. For critical non-idempotent operations (payments, transfers), require an `Idempotency-Key` header. Store the key server-side; if the same key arrives again, return the original response without re-executing.

## Authentication

Use standard patterns: Bearer tokens in the `Authorization` header, or API keys in a custom header (`X-API-Key`). Never pass credentials in query strings — URLs are logged by proxies, browsers, and CDNs. Use HTTPS always. Return 401 for missing/invalid credentials, 403 for valid credentials with insufficient permissions.

## Developer Experience (DX) Review (from gstack)

For developer-facing products (APIs, SDKs, CLIs, libraries), evaluate across 8 DX dimensions:

| Dimension | What to Measure | Good Target |
|-----------|----------------|-------------|
| **TTHW (Time To Hello World)** | How long from zero to first successful API call? | < 5 minutes |
| **Error messages** | Do errors tell you WHAT went wrong AND what to do next? | Every error is actionable |
| **Documentation** | Can a developer find the answer without asking support? | Self-service for 90% of questions |
| **Authentication** | How many steps to get a working API key? | < 3 steps |
| **SDK quality** | Does the SDK match the API 1:1? Type-safe? Up to date? | Parity with API, auto-generated |
| **Debugging** | Can you see what's happening? Request logs, tracing, verbose mode? | Request ID in every response |
| **Migration path** | Is upgrading from v1→v2 documented with examples? | Migration guide with before/after |
| **Failure modes** | What happens when the API is down? Rate limited? Timeout? | Graceful degradation documented |

**TTHW is the single most important metric.** Measure it by: clone repo → install → first successful call. If it takes more than 5 minutes, something is broken in the onboarding path.

Evaluate competitively: how does your TTHW compare to alternatives? If a competitor's TTHW is 2 minutes and yours is 20 minutes, you lose developers regardless of feature superiority.
