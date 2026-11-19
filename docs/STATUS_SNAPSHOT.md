# Status Snapshot Architecture

## 1. Overview

The Status page previously generated GitHub metrics synchronously. As the number of teams and sprints increased, these requests could exceed the page's request timeout.

The background snapshot workflow separates metric generation from page rendering, allowing users to continue viewing previously cached metrics while updated data is generated.

## 2. Architecture

The implementation introduces three components:

| Component | Responsibility |
|---|---|
| `StatusSnapshotService` | Collects and calculates team and sprint metrics. |
| `StatusSnapshotJob` | Executes snapshot generation in the background and stores the resulting payload. |
| `StatusSnapshotCoordinator` | Manages cached snapshots, refresh requests, and duplicate generation prevention. |

The Semesters controller retrieves cached snapshot data and renders the Status page.

## 3. Snapshot Workflow

1. The user selects a semester and opens the Status page.
2. The application checks for an existing snapshot.
3. If no snapshot exists, the user is prompted to generate one.
4. Snapshot generation is scheduled as a background job.
5. The page automatically polls for completion every five seconds.
6. Once generation finishes, the updated metrics are displayed.

During subsequent refreshes, the previous snapshot remains visible. If generation fails, the previous snapshot is preserved and the user can retry.

## 4. Cache Management

Snapshots are isolated by semester and user.

The cache key incorporates a fingerprint of the semester's sprint IDs, names, and dates. Changes to sprint configuration invalidate previously generated snapshots.

A temporary refresh marker prevents duplicate generation requests for the same snapshot key. The marker expires after 30 minutes.

Snapshots are refreshed manually rather than regenerated automatically on every page visit.

## 5. User Interface

The Status page provides:

- Initial snapshot generation prompt.
- Manual snapshot refresh.
- Background generation notifications.
- Automatic polling for completed snapshots.
- Dynamic snapshot age indicator.
- Snapshot generation failure notifications.
- Continued access to previously cached metrics during background updates.

The snapshot age indicator updates every second without requiring additional server requests.

## 6. Authorization

Administrators and teaching assistants can browse and select semesters, access the Status page, and request snapshot generation.

Semester creation, editing, and deletion remain restricted to administrators.

Students and guests cannot access the Status page or request snapshot generation.

## 7. Environment Configuration

| Variable | Default | Description |
|---|---|---|
| `STATUS_BACKGROUND_ENABLED` | True outside production; false in production | Enables background snapshot generation. |
| `STATUS_PARALLELISM` | 2 | Maximum number of concurrent team-processing threads per background snapshot. |
| `REDIS_URL` | Unset | Configures a shared Redis cache in production when provided. |

When background generation is disabled, the application uses synchronous snapshot generation and caching.

## 8. Production Deployment Considerations

The local development environment uses Rails AsyncAdapter and MemoryStore. Both operate within the application process.

These components have limitations in a Google Cloud Run deployment:

- In-memory snapshots may be lost when containers restart.
- Multiple application instances do not share MemoryStore snapshots.
- In-process background jobs may be interrupted during container shutdown.
- Request-based CPU allocation may interfere with background processing.

Reliable production background processing requires a shared cache, persistent job queue, and suitable worker execution environment.

Potential solutions include Redis and Sidekiq or a PostgreSQL-backed job queue with a compatible shared cache.

Background generation is disabled by default in production until these requirements are addressed. Setting `STATUS_BACKGROUND_ENABLED=true` alone does not guarantee reliable background processing.

The synchronous fallback remains susceptible to the original request timeout issue.

## 9. Testing

The combined regression suite produced the following results:

- Tests executed: 44
- Assertions: 196
- Failures: 0
- Errors: 0
- Skips: 0

Testing covers snapshot generation, cache retrieval, duplicate refresh prevention, sprint-based cache invalidation, failure handling, synchronous fallback behavior, and role-based authorization.

Production-scale performance and concurrent refreshes across multiple users and application instances require further validation.

## 10. Future Improvements

- Configure persistent background job processing for production.
- Configure shared snapshot storage.
- Evaluate performance with larger semesters.
- Optimize GitHub API requests and database connection usage.
- Improve cache invalidation for team and student membership changes.
- Strengthen refresh coordination across concurrent workers and application instances.

## Status Snapshot Configuration

The Status page supports background snapshot generation to reduce
request timeouts during GitHub metric collection.

Background generation is disabled by default in production.
Before enabling it, configure shared caching, persistent background
job processing, and a suitable worker execution environment.

See [Status Snapshot Architecture](STATUS_SNAPSHOT.md) for configuration
options, deployment requirements, and known limitations.

## 11. Full-Roster Scalability Validation

The background snapshot implementation was manually tested using a full semester roster consisting of 11 teams and approximately 44 students.

Initial snapshot generation and subsequent manual refreshes completed successfully without encountering request timeouts.

All team status data was displayed, existing metrics remained accessible during background refreshes, and the snapshot age indicator correctly reset upon completion.

Reloading the Status page successfully retrieved the existing cached
snapshot without triggering unnecessary regeneration or resetting
the snapshot age.

These results demonstrate that the implementation can accommodate the current semester workload in the local development environment. Production infrastructure configuration, concurrent-user testing, and deployment validation remain outstanding.