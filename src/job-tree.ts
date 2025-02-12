import type { TaskSpec } from "graphile-worker";
import type { PoolClient } from "pg";

import pg from "pg";

type KnownTaskSpecs = {
  [TaskName in keyof GraphileWorker.Tasks]: GraphileWorker.Tasks[TaskName] extends undefined
    ? {
        identifier: TaskName;
        payload?: GraphileWorker.Tasks[TaskName];
      }
    : {
        identifier: TaskName;
        payload: GraphileWorker.Tasks[TaskName];
      };
}[keyof GraphileWorker.Tasks];

type DefaultTaskSpec = {
  identifier: string & {};
  payload?: unknown;
};

export interface ExtendedTaskSpec extends TaskSpec {
  identifier: keyof GraphileWorker.Tasks | string;
  payload?: unknown;
  onFailure?: "fail-parent" | "remove" | "ignore";
}

export type TaskTreeSpec = ExtendedTaskSpec &
  (KnownTaskSpecs | DefaultTaskSpec) & {
    children?: TaskTreeSpec[];
  };

interface JobOptions {
  parentId?: bigint;
  useNodeTime?: boolean;
}

const getValues = (spec: ExtendedTaskSpec, options: JobOptions = {}) => {
  const { parentId = null, useNodeTime = true } = options;

  return [
    parentId,
    false,
    spec.onFailure ?? null,
    spec.identifier,
    spec.payload ?? null,
    spec.queueName ?? null,
    spec.runAt?.toISOString() ??
      (useNodeTime ? new Date().toISOString() : null),
    spec.maxAttempts ?? null,
    spec.jobKey ?? null,
    spec.priority ?? null,
    spec.flags ?? null,
    spec.jobKeyMode ?? null,
  ];
};

const PARAMETERS = [
  ["parent_id", "bigint"],
  ["on_failure", "text"],
  ["identifier", "text"],
  ["payload", "json"],
  ["queue_name", "text"],
  ["run_at", "timestamptz"],
  ["max_attempts", "integer"],
  ["job_key", "text"],
  ["priority", "integer"],
  ["flags", "text[]"],
  ["job_key_mode", "text"],
] as const;
const PARAMETERS_NAMES = PARAMETERS.map(([name]) => name);
const PARAMETERS_TYPES = PARAMETERS.map(([, type]) => type);
const PARAMETER_COUNT = Object.keys(PARAMETERS).length;

const insertJobDependencies = (
  pgClient: PoolClient,
  valueObjects: TaskTreeSpec[],
  options?: JobOptions
) => {
  const valueParameters = valueObjects
    .map((_, i) => {
      const parameters = PARAMETERS_TYPES.map(
        (type, pos) => `$${i * PARAMETER_COUNT + pos + 1}::${type}`
      ).join(",");

      return `(${parameters})`;
    })
    .join(", ");
  const values = valueObjects.flatMap((valueObject) =>
    getValues(valueObject, options)
  );

  return pgClient.query<{ id: bigint }>(
    /* sql */ `INSERT INTO graphile_worker_extension.job_dependencies (${PARAMETERS_NAMES.map(
      (parameter) => pgClient.escapeIdentifier(parameter)
    ).join(", ")}) VALUES ${valueParameters} RETURNING id`,
    values
  );
};

export const addJobTree =
  (spec: TaskTreeSpec, useNodeTime = true) =>
  async (pgClient: PoolClient) => {
    await pgClient.query(/* sql */ `BEGIN`);

    try {
      pgClient.setTypeParser(pg.types.builtins.INT8, BigInt);

      const {
        rows: [root],
      } = await insertJobDependencies(pgClient, [spec], { useNodeTime });
      const stack = [[root.id, spec.children]] as Array<
        [bigint, TaskTreeSpec["children"]]
      >;
      const readyJobIds = new Array<bigint>();

      while (stack.length) {
        const batch = stack.pop();
        const [parentId, children] = batch!;

        readyJobIds.push(parentId);

        if (!children?.length) {
          continue;
        }

        const { rows: childrenIds } = await insertJobDependencies(
          pgClient,
          children,
          {
            parentId,
            useNodeTime,
          }
        );

        childrenIds.forEach((childrenId, i) => {
          const grandchildren = children[i].children;

          if (!grandchildren?.length) {
            readyJobIds.push(childrenId.id);
          } else {
            stack.push([childrenId.id, grandchildren]);
          }
        });
      }

      await pgClient.query(
        /* sql */ `\
UPDATE graphile_worker_extension.job_dependencies SET is_ready = true
WHERE NOT is_ready AND id = ANY($1)`,
        [readyJobIds]
      );

      await pgClient.query(/* sql */ `COMMIT`);
    } catch (e) {
      console.error(e);

      await pgClient.query(/* sql */ `ROLLBACK`);
    }
  };
