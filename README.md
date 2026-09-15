# Dept Collect Microservice Backend

Debt-collection microservices platform built with Java 21, Spring Boot 3.5.12 and Flowable. Four Spring Boot services orchestrate debt recovery end-to-end: automated staging decisions (DMN), human agent tasks (BPMN), case snapshots and email notifications.

Version `0.1.0-SNAPSHOT` — Maven multi-module reactor, built with the system `mvn` (no wrapper). This repository is not a git repo and currently contains no tests and no CI.

## Architecture

Modules (from the root `pom.xml`, built in this order):

| Module | Role |
|---|---|
| `shared-kernel` | Cross-cutting library compiled into every service: `X-Tenant-Id` / `X-Correlation-Id` filters, a global `@RestControllerAdvice` mapping exceptions to RFC-9457 `ProblemDetail`, and `GET /api/v1/_service` (tenant-guarded service info). |
| `services/case-service` | Case file management: create-or-get case, list, fetch, status update. JPA + Flyway on the `case_service` database. |
| `services/segmentation-service` | DMN decision engine: stages a debt (IFRS-9-style ageing + exposure), computes priority, recommended action and customer segment. Flowable DMN, own `segmentation_service` database. |
| `services/workflow-service` | Orchestration: runs the French-labelled BPMN debt-recovery process on Flowable, calls the three other services via `RestClient`, writes outbox events. |
| `services/notification-service` | Email delivery via SMTP (MailHog in dev) with per-tenant delivery records persisted in `notification_service`. |

Call graph: `workflow-service` is the only service that calls others —

- `SegmentationClient` → `POST /api/v1/segmentation/staging/execute`
- `CaseServiceClient` → `POST /api/v1/cases`
- `NotificationClient` → `POST /api/v1/notifications/email`

## Tech stack

| Concern | Choice |
|---|---|
| Runtime | Java 21 |
| Framework | Spring Boot 3.5.12 (BOM imported in the root pom) |
| Workflow / decisions | Flowable 7.2.0 (process engine in workflow-service, DMN engine in segmentation-service) |
| Database | PostgreSQL 17 (Docker), one schema per service |
| Persistence | Spring Data JPA + Flyway (`ddl-auto: validate`) in case-, workflow-, notification-service; Flowable-managed `ACT_*`/DMN tables in workflow- and segmentation-service |
| API docs | springdoc-openapi 2.8.9 (`/swagger-ui/index.html` per service) |
| Build | Maven (`mvn` only, no wrapper), reactor root `backend/pom.xml` |
| Local infra | Docker Compose: PostgreSQL + MailHog |

## Getting started

Prerequisites:

- JDK 21
- Maven 3.x on the system `PATH` (no Maven wrapper is committed)
- Docker with Compose for local infrastructure

### 1. Start infrastructure

From this directory (`backend/`):

```sh
docker compose up
```

- PostgreSQL on host port **5433** (user/pass `collector`/`collector` — not the usual 5432/`postgres`)
- MailHog: SMTP on port **1035**, web UI at http://localhost:8035

`infra/init-databases.sql` creates the four schemas (`case_service`, `segmentation_service`, `workflow_service`, `notification_service`) and only runs on a **fresh** volume. After editing it, recreate with `docker compose down -v`.

### 2. Build

```sh
mvn clean verify
```

Run from `backend/` — the reactor builds `shared-kernel` first, then the four services.

### 3. Run a service

```sh
mvn -pl services/<svc> -am spring-boot:run
```

The `-am` flag is required so the `shared-kernel` dependency resolves in the same reactor; `mvn spring-boot:run` from inside a service directory only works after `shared-kernel` has been installed locally.

| Service | Port | Postgres schema | Swagger UI |
|---|---|---|---|
| case-service | 8091 | case_service | http://localhost:8091/swagger-ui/index.html |
| segmentation-service | 8092 | segmentation_service | http://localhost:8092/swagger-ui/index.html |
| workflow-service | 8094 | workflow_service | http://localhost:8094/swagger-ui/index.html |
| notification-service | 8095 | notification_service | http://localhost:8095/swagger-ui/index.html |

Health endpoint (tenant-exempt): `http://localhost:<port>/actuator/health`.

Database connection is overridable via environment variables (`DB_URL`, `DB_USER`, `DB_PASSWORD`); each service defaults to `jdbc:postgresql://localhost:5433/<schema>` with `collector`/`collector`. Server ports are overridable via `SERVER_PORT`.

## Multi-tenancy

Every endpoint **except** `/actuator*`, `/swagger-ui*`, `/v3/api-docs*` and Flowable's `/process-api`, `/cmmn-api`, `/dmn-api` requires the `X-Tenant-Id` header. A missing or blank header returns `400`.

```sh
curl -H "X-Tenant-Id: tenant-demo" http://localhost:8091/api/v1/_service
```

- `X-Correlation-Id`: if present it is propagated and echoed on the response; if absent a UUID is generated. It is kept in the SLF4J MDC under `correlationId` and printed by the log pattern.
- `TenantContext` is a `ThreadLocal` populated by `TenantContextFilter`. Flowable async-executor threads do **not** carry it — delegates read `tenantId` from process variables instead of calling `TenantContext.getRequiredTenantId()`.

## API summary

### case-service — `/api/v1/cases`

| Method | Path | Description |
|---|---|---|
| POST | `/api/v1/cases` | Create or get existing case |
| GET | `/api/v1/cases` | List cases |
| GET | `/api/v1/cases/{id}` | Fetch one case |
| PATCH | `/api/v1/cases/{id}/status` | Update status / assigned collector |

### segmentation-service — `/api/v1/segmentation/staging`

| Method | Path | Description |
|---|---|---|
| POST | `/execute` | Execute the DMN staging chain and persist result |
| POST | `/simulate` | Same decisions, simulation only |

### workflow-service — `/api/v1/workflows`

| Method | Path | Description |
|---|---|---|
| POST | `/banking-recovery/start` | Start a full banking-recovery process (201 on creation) |
| POST | `/banking-recovery/processes` | Start process, idempotent-style response |
| GET | `/tasks` | Active tasks |
| POST | `/tasks/{taskId}/assign`, `/tasks/{taskId}/complete` | Assign / complete a task |
| POST | `/tasks/{taskId}/actions/{promise-payment\|payment-plan\|contact-customer\|formal-notice\|escalate\|close}` | Agent actions on tasks |
| POST | `/cases/{caseId}/payment` | Correlate a payment message to a running process |
| GET | `/processes/{processInstanceId}/history` | Process history |
| GET/POST | `/processes/{processInstanceId}/variables` | Read / write process variables |
| GET | `/processes/{processInstanceId}/incidents` | Process incidents |
| GET | `/processes/{processInstanceId}/jobs/dead`, POST `/jobs/{jobId}/retry` | Dead-letter jobs and retry |
| GET | `/processes/{processInstanceId}/timers`, POST `/timers/{timerId}/trigger` | Timers and manual trigger |

### notification-service — `/api/v1/notifications`

| Method | Path | Description |
|---|---|---|
| POST | `/email` | Send an email through SMTP (MailHog) and record the delivery |
| GET | `/email` | List deliveries for the current tenant |

## Key design notes

- **Deliberate resilience in workflow-service.** `CaseServiceClient` and `NotificationClient` catch exceptions and log warnings only; `StageRecoveryDelegate` falls back to a local algorithm (`stageLocally`) when segmentation-service is unavailable and sets the process variable `stagingSource=LOCAL`. These swallowed failures are intended behavior, not bugs.
- **Tenant isolation across async execution.** Process variables carry `tenantId` (set at process start); delegates never rely on the request-scoped `ThreadLocal` because Flowable's async-executor threads do not have the tenant context.
- **Flowable configuration.** `enableSafeBpmnXml(false)` and `async-executor-activate: true` are set in `FlowableConfig`; the process engine manages its own `ACT_*` tables (`database-schema-update: true`).
- **Timers are demo values, not production.** In `banking-recovery-process.bpmn20.xml`: the SLA reminder boundary timer is `PT2M` (labelled "Relance SLA (2 jours)") and the payment-deadline catch event is `PT1M` (with a comment noting the production value is `P7D`).
- **Package-name split.** Everything is `com.deptcollector.*` except workflow-service, which keeps the legacy `com.mercure.recouvrement.workflow` namespace — including the BPMN target namespace and the hardcoded `flowable:class` / `delegateExpression` references. Renaming beans or classes breaks the process deployment silently.
- **French process assets.** BPMN activity names and DMN decision names/labels are in French; keep that style for new process and decision assets.

## Database / outbox notes

- **workflow-service — `outbox_event`** (Flyway `V1__baseline.sql`): holds `CaseStatusChanged` / `TaskActionPerformed` events written by `OutboxEventWriter` (fields: `tenant_id`, `aggregate_type`, `aggregate_id`, `event_type`, `payload` JSONB, `occurred_at`, nullable `published_at`). A partial index `idx_outbox_unpublished` targets rows where `published_at IS NULL` for later publication by an external relay. Flyway in workflow-service only owns this table.
- **notification-service — `email_delivery`** (Flyway `V1__email_delivery.sql`): one row per send attempt — `tenant_id`, `recipient`, `subject`, `template_name`, `trigger_type`, `status`, `error_message`, `sent_at` — indexed per tenant by `sent_at DESC`.
- **case-service — `collection_case`** (Flyway `V1__collection_case.sql`): unique per tenant on `(tenant_id, case_reference)`, created/updated by workflow-service during process execution.
- **segmentation-service** has no Flyway migrations; Flowable DMN engine tables are created via `flowable.dmn.database-schema-update: true`.
- case-, notification- and workflow-service run with JPA `ddl-auto: validate` — entity classes must match the `V1__*.sql` migrations exactly or startup fails.