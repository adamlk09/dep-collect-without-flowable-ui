# AGENTS.md

Java 21 · Spring Boot 3.5.12 · Flowable 7.2.0. Debt-collection backend: 4 Spring Boot services + a `shared-kernel` library module, built with Maven (no wrapper). No git repo, no CI, no README — do not expect build-hygiene gates to exist.

## Layout & ownership
- Root `pom.xml` aggregates (build from `backend/`): `shared-kernel`, then `services/{segmentation,case,workflow,notification}-service`.
- `shared-kernel` ships the cross-cutting MVC pieces every service compiles in: `X-Tenant-Id` / `X-Correlation-Id` filters, a global `@RestControllerAdvice` that maps exceptions to RFC-9457 `ProblemDetail` (validation→400, `IllegalArgumentException`→400, `IllegalStateException`→409, `NoSuchElementException`→404), and `GET /api/v1/_service` (tenant-guarded).
- `workflow-service` is the only service that calls others (segmentation, case, notification) via `RestClient` in `com.mercure.recouvrement.workflow.client`.
- One app class per service: `services/<svc>/src/main/java/<pkg>/<Svc>Application.java`.

## Build & run
- Use system `mvn` (no wrapper), Java 21.
- Full build from `backend/`: `mvn clean verify` (also installs `shared-kernel` into `~/.m2`).
- Run a single service from `backend/`: `mvn -pl services/<svc> -am spring-boot:run` (the `-am` is required so the `shared-kernel` dependency resolves; `mvn spring-boot:run` from inside a service dir only works after `shared-kernel` is installed).
- `mvn test` compiles but there are currently **no tests** in any module.
- `*.log` files at `backend/` root are leftovers from local `mvn spring-boot:run` runs, not source.

## Infra & ports (`compose.yaml`)
| Service | Port | Postgres schema |
|---|---|---|
| case-service | 8091 | case_service |
| segmentation-service | 8092 | segmentation_service |
| workflow-service | 8094 | workflow_service |
| notification-service | 8095 | notification_service |

- `docker compose up` gives you Postgres on **host port 5433** (user/pass `collector`/`collector` — not the usual `postgres`/5432) and MailHog (SMTP 1035, UI http://localhost:8035).
- `infra/init-databases.sql` only runs on a **fresh** volume; after editing it, `docker compose down -v` to recreate.
- Services default to `DB_URL=jdbc:postgresql://localhost:5433/<schema>`, `DB_USER`/`DB_PASSWORD` overridable.
- swagger UI (`/swagger-ui.html`) and `/actuator/health` are exempt from tenant checks.

## Multi-tenancy & headers
- Every endpoint except `/actuator*`, `/swagger-ui*`, `/v3/api-docs*`, and Flowable's `/process-api`, `/cmmn-api`, `/dmn-api` **requires `X-Tenant-Id`** → 400 otherwise. All API calls (curl, tests) need it.
- `X-Correlation-Id`: generated if absent, kept in SLF4J MDC (`correlationId`), echoed on the response, and printed by the log pattern.
- `TenantContext` is a `ThreadLocal`; Flowable async-executor threads do **not** have it. Delegates read `tenantId` from process variables instead — do not call `TenantContext.getRequiredTenantId()` inside a `JavaDelegate`.

## Cross-service integration (workflow-service)
- Base URLs are props with env overrides `SEGMENTATION_SERVICE_URL`, `CASE_SERVICE_URL`, `NOTIFICATION_SERVICE_URL` (defaults localhost:8092/8091/8095).
- Failures are **deliberately swallowed by design**: `CaseServiceClient` and `NotificationClient` catch and log warnings only; `StageRecoveryDelegate` falls back to a local algorithm (`stageLocally`) when segmentation-service is down and sets `stagingSource=LOCAL`. Don't "fix" these as bugs.
- `SegmentationClient` DTOs (`client/*`) duplicate segmentation-service's `api/dto/*` — keep them in sync manually.

## Flowable / DMN gotchas (easy to break)
- `banking-recovery-process.bpmn20.xml` hardcodes `flowable:class="com.mercure.recouvrement.workflow.delegate.ApplyStrategyDelegate"` and delegateExpression bean names (`stageRecoveryDelegate`, `extractIrregularAccountDelegate`, `checkReachabilityDelegate`, `sendReminderDelegate`, `bumpToSeniorLevelDelegate`). Renaming beans/classes breaks the process silently.
- Timers are demo values, not production: SLA reminder `PT2M` (comment says 2 days), payment deadline `PT1M` (comment says P7D).
- `FlowableConfig` sets `enableSafeBpmnXml(false)`; `async-executor-activate: true`; Flowable manages its own `ACT_*` tables (`database-schema-update: true`).
- segmentation-service DMN files in `resources/dmn/*.dmn`, keys `collectionStagingDecision`, `collectionPriorityDecision`, `collectionActionDecision`, `customerSegmentationDecision` (evaluated as a chain in `CollectionDecisionService`). `flowable.dmn.strict-mode: false`.
- case-, notification-, and workflow-service use Flyway + JPA `ddl-auto: validate` — entities must match the `V1__*.sql` migrations exactly or startup fails. workflow-service Flyway only owns `outbox_event`.

## Conventions
- **Package-name split:** everything is `com.deptcollector.*` except `workflow-service`, which uses the legacy `com.mercure.recouvrement.workflow` namespace (also in the BPMN namespace and `flowable:class` refs). Preserve it when editing workflow code.
- BPMN/DMN labels are French; keep that style for new process/decision assets.
