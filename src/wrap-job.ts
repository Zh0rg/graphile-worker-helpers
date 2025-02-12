import type { JobHelpers, PromiseOrDirect, Task } from "graphile-worker";
import { updateJobProgress } from "./job-helpers";

export const wrapJob = <
  TName extends keyof GraphileWorker.Tasks | string = string
>(
  task: (
    payload: TName extends keyof GraphileWorker.Tasks
      ? GraphileWorker.Tasks[TName]
      : unknown,
    helpers: JobHelpers
  ) => PromiseOrDirect<void | unknown>
) => {
  return (async (payload, helpers) => {
    const { withPgClient, job } = helpers;

    const result = await task(payload, helpers);

    await withPgClient(updateJobProgress(job, result));
  }) as Task<TName>;
};
