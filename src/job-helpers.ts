import type { Job, JobHelpers } from "graphile-worker";
import type { PoolClient } from "pg";

export const updateJobProgress =
  (job: Job, data?: unknown) => (pgClient: PoolClient) =>
    pgClient.query(
      /* sql */ `UPDATE graphile_worker_helpers.job_results SET results = $1::json WHERE id = $2::bigint AND NOT is_complete`,
      [JSON.stringify(data) ?? null, job.id]
    );

export const recoverJobProgress = async <D>(
  job: Job,
  query: JobHelpers["query"]
): Promise<D | null> => {
  const {
    rows: [{ results = null } = {}],
  } = await query<{ results: D }>(
    /* sql */ `SELECT results FROM graphile_worker_helpers.job_results WHERE id = $1::bigint AND NOT is_complete`,
    [job.id]
  );

  return results;
};

const getChildrenResults = async (
  job: Job,
  query: JobHelpers["query"],
  filter?: string
) => {
  const { rows: childrenValue } = await query<{
    id: Job["id"];
    results: unknown;
  }>(
    /* sql */ `SELECT results.id, results.results
FROM graphile_worker_helpers.job_dependencies AS parent
  INNER JOIN graphile_worker_helpers.job_dependencies AS children_jobs ON parent.id = children_jobs.parent_id
  INNER JOIN graphile_worker_helpers.job_results AS results ON children_jobs.result_id = results.id
WHERE parent.result_id = $1::bigint${filter ? " AND " + filter : ""}`,
    [job.id]
  );

  return Object.fromEntries(
    childrenValue.map(({ id, results }) => [id, results])
  ) as Record<Job["id"], unknown>;
};

export const getChildrenValues = async (job: Job, query: JobHelpers["query"]) =>
  getChildrenResults(job, query, /* sql */ `NOT children_jobs.has_failed`);

export const getFailedChildrenValues = async (
  job: Job,
  query: JobHelpers["query"]
) => getChildrenResults(job, query, /* sql */ `children_jobs.has_failed`);
