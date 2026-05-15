---
name: contract-testing
description: Service contract verification. Use when testing interactions between services — HTTP APIs, message queues, event streams. Invoke when integration tests are too slow or brittle, or when you need to verify that producer and consumer agree on the data contract without deploying both.
---

# Contract Testing

## Core Principle

Integration tests tell you that two services work together today. Contract tests tell you that they will still work together after either side changes. Contracts are versioned promises — consumers define what they need, providers verify they deliver it. No shared environment, no coordination overhead, no flaky network.

## When NOT to Use

Do not use this skill for unit tests within a single service. Contract tests are for service boundaries. Testing internal logic, private methods, or components within the same deployment unit uses unit or integration testing skills instead.

## Two Roles: Consumer and Provider

Every contract test involves two parties:

**Consumer** — the service that calls the API or reads the message. The consumer defines the contract: "I need this shape of response when I send this request." The consumer does not test the provider's full behavior — only the subset it depends on.

**Provider** — the service that implements the API or produces the message. The provider fetches all consumer contracts from the broker and verifies that its current implementation satisfies each one. If a provider change breaks a consumer contract, the CI pipeline catches it before deploy.

## Five Core Techniques

### 1. Consumer-Driven Contracts (CDC)
The consumer writes the contract, not the provider. This is non-negotiable. Provider-written contracts test what the provider thinks consumers need, not what they actually need. The standard tool is Pact. The consumer defines interactions (request + expected response), runs them against a Pact mock server to generate a contract file, and publishes the contract to a Pact Broker. The provider pulls from the broker and verifies.

Consumer side (Pact example pattern):
```
interaction:
  description: "get user by id"
  request:   { method: GET, path: /users/123 }
  response:  { status: 200, body: { id: 123, email: "..." } }
```

The consumer only specifies fields it uses. Extra fields in the provider response are allowed and ignored.

### 2. Schema Versioning
Contracts are versioned. Breaking changes require a new contract version. Providers must support at least N-1 versions during the migration window. The Pact Broker tracks which consumer versions are in production — `can-i-deploy` checks prevent a provider from removing support for a version that is still live.

### 3. Provider State Setup
Before verifying a consumer interaction, the provider must be in the state the interaction assumes. A consumer contract for "get order by id returns 404" requires the provider to set up a state where that order does not exist. Provider states are declared by name in the contract and implemented as state handlers in the provider's verification test setup.

```
// Provider state handler
"order 999 does not exist" → delete order 999 from test DB (or use in-memory mock)
```

State handlers are test infrastructure, not production code. They run in the provider's test suite only.

### 4. Backwards Compatibility Check
Classify every proposed provider change before merging:
- **Safe:** adding new fields, adding new optional query params, adding new endpoints
- **Breaking:** removing a field, renaming a field, changing a field's type, making an optional field required, changing URL structure, changing error codes consumers switch on

When in doubt, it is breaking. Run `can-i-deploy` against the Pact Broker to get a definitive answer based on registered consumer contracts.

### 5. Async Contract Testing
For event-driven systems, verify message schemas using Pact's `MessageConsumerPact` or AsyncAPI spec validation. The consumer defines the message shape it expects. The provider (message producer) verifies it produces messages matching that shape. No live broker required — the contract is the artifact.

## Contract Test Anatomy

```
Consumer CI pipeline:
  1. Consumer tests run against Pact mock server
  2. Pact generates contract file from interactions
  3. Contract published to Pact Broker with consumer version tag

Provider CI pipeline:
  1. Provider fetches consumer contracts from Pact Broker
  2. Provider state handlers set up required states
  3. Provider verifies each consumer interaction against its live code
  4. `can-i-deploy` gate: block deploy if any consumer contract breaks
```

## Anti-Patterns

- **Using contract tests as integration tests** — contract tests must be fast and in-memory. If your contract test makes a real HTTP call over a network, it is an integration test wearing a contract-test costume. Use a Pact mock server on the consumer side; the provider verifies against its own local stack.
- **Provider teams writing consumer contracts** — this defeats the consumer-driven purpose. The consumer knows what it needs; the provider does not.
- **Not running contract tests in CI** — a contract test run manually before every deploy is a contract test that will eventually be skipped. Automate it or treat it as non-existent.
- **Forgetting to version contracts** — a provider change that silently removes a field used by a consumer is a production incident. The Pact Broker's `can-i-deploy` check is the mechanical guard; it only works if contracts are published with version tags.
- **Testing the full provider API from the consumer** — consumer contracts should specify only the fields the consumer actually uses. Over-specified contracts break on every irrelevant provider change, creating noise and eroding trust in the signal.
