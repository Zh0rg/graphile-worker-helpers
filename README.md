# Graphile worker helpers

A set of helpers adding hierarchy and job progress functionnality to the [graphile-worker](https://github.com/graphile/worker) package inspired by [BullMQ's Flow](https://docs.bullmq.io/guide/flows) as well as saving intermediary results for improved job recovery and progress management.

## Installation

All tables will be created in the `graphile_worker_helpers` and assume that `graphile-worker` was installed in the `graphile_worker` schema.

## Performance hit

When many jobs with the same parent finish around the same time, they may take time to complete.

## Handling child job failure

Similar to BullMQ, you can chose what happens when a child job fails permanently:

- `fail-parent` (*default*): fail the parent when a child fails. Can be recursive if the parent has the same option.
- `ignore`: the error is ignored and the job is marked as completed. The parent can still access the intermediate result.
- `remove`: the job and its relation to the parent are removed. The intermediate result is lost if there was any.

## Functions

Here is an exhaustive list of the functions exported by the package.

### Setup / removal

Use the `setup` and `remove` functions to migrate up and down respectively.
These functions needs a `PoolClient` instance from the `pg` package. You can get one from the `withPgClient` function from the `WorkerUtils`, `JobHelpers` or `Helpers` type.

Example:

```typescript
import { makeWorkerUtils } from "graphile-worker"
import { 
  setup as graphileWorkerExtensionSetup,
  remove as graphileWorkerExtensionRemove,
} from "graphile-worker-extension"

import graphileConfig from "./graphile.config"

async function main() {
    const workerUtils = await makeWorkerUtils({
        preset: graphileConfig
    })
    
    await workerUtils.withPgClient(graphileWorkerExtensionSetup())
    
    // Create some jobs...
    
    await workerUtils.withPgClient(graphileWorkerExtensionRemove())
    await workerUtils.release()
}

main().catch(err => {
    console.log(err)
    process.exit(1)
})

```

### Saving job output

- `wrapJob`: An optional function that allows the return value of a job to be saved to be used by the parent. If an intermediate result was stored and the function doesn't return anything, the stored result will be overwritten with `null`

    Examples:

    ```typescript
    // tasks/get-four.ts
    import { wrapJob } from "graphile-worker-extension"

    export default wrapJob<"get-four">((payload, _helpers) => 4)

    ```

    ```typescript
    // worker.ts
    import { run } from "graphile-worker"
    import { wrapJob } from "graphile-worker-extension"

    import graphileConfig from "./graphile.config"

    async function main() {
        const runner = await run({
            preset: graphileConfig,
            taskList: {
                getFour: wrapJob<"getFour">((payload, _helpers) => 4)
            },
            forbiddenFlags: rateLimiter.getForbiddenFlags,
        });

        await runner.promise;
    }

    main().catch(err => {
        console.log(err)
        process.exit(1)
    })
    ```

- `updateJobProgress`: Updates the result stored in the database.   The value can be anything that is JSON serializable.

    Example:

    ```typescript
    // worker.ts
    import { run, type Task } from "graphile-worker"
    import { updateJobProgress } from "graphile-worker-extension"

    import graphileConfig from "./graphile.config"

    const getFour: Task<"getFour"> = async (_, helpers) => {
        await helpers.withPgClient(updateJobProgress(helpers.job, 4))
    }

    async function main() {
        const runner = await run({
            preset: graphileConfig,
            taskList: {
                getFour
            },
            forbiddenFlags: rateLimiter.getForbiddenFlags,
        });

        await runner.promise;
    }

    main().catch(err => {
        console.log(err)
        process.exit(1)
    })
    ```

### Job creation

- `addJobTree`: Insert a job tree. All leaf jobs are started at the same time. All options from `addJob` can be passed.

    Example:

    ```typescript
    // index.ts
    import { makeWorkerUtils } from "graphile-worker"
    import { 
    setup as graphileWorkerExtensionSetup,
    remove as graphileWorkerExtensionRemove,
    addJobTree
    } from "graphile-worker-extension"

    import graphileConfig from "./graphile.config"

    async function main() {
        const workerUtils = await makeWorkerUtils({
            preset: graphileConfig
        })
        
        await workerUtils.withPgClient(graphileWorkerExtensionSetup)
        
        await addJobTree({
            identifier: "root-job",
            children: [
                {
                    identifier: "job1",
                    payload: {
                        hello: "world"
                    },
                    onFailure: "ignore"
                },
                {
                    identifier: "job2",
                    onFailure: "remove"
                },
                {
                    identifier: "send-mail",
                    payload: {
                        to: "john.doe@example.com",
                        msg: "Hello"
                    },
                    // Default
                    onFailure: "fail-parent"
                }
            ]
        })
        
        await workerUtils.withPgClient(graphileWorkerExtensionRemove)
        await workerUtils.release()
    }

    main().catch(err => {
        console.log(err)
        process.exit(1)
    })
    ```

### Result retrieval

- `getChildrenValues`: Retrieves the results of successful children as an object with the job IDs as keys. The function takes the `job` and `query` properties of the `helpers` object passed to the job.

    Example

    ```typescript
    // worker.ts
    import { run } from "graphile-worker";
    import { getChildrenValues, wrapJob } from "graphile-worker-extension";

    import graphileConfig from "./graphile.config";

    const writeReport = wrapJob<"report">(async (payload, helpers) => {
        helpers.logger.info(`Writing report for user#${payload.userId}`);

        const childrenResults = await getChildrenValues(
            helpers.job,
            helpers.query
        )

        const {
            rows: [report],
        } = await helpers.query(
            /* sql */ `UPDATE reports SET data = $1::json, completed = true WHERE id = $2`,
            [JSON.stringify(Object.values(childrenResults).flat()), payload.userId]
        );

        return report;
    });

    async function main() {
        const runner = await run({
            preset: graphileConfig,
            taskList: {
                report: writeReport,
            },
        });

        await runner.promise;
    }

    main().catch((err) => {
        console.error(err);
        process.exit(1);
    });
    ```

- `getFailedChildrenValues`: Retrieves the results of failed children as an object with the job IDs as keys. Usage is the same as `getChildrenValues`
- `recoverJobProgress`: Retrieves the intermediate result from the previous attempts. Returns `null` on the first attempt.

    Example:

    ```typescript
    // dummy-job.ts
    import { run } from "graphile-worker";
    import { recoverJobProgress } from "graphile-worker-extension";

    export default async (payload, helpers) => {
        helpers.logger.info("Starting dummy job");

        const previousResults = (await recoverJobProgress<unknown[]>(helpers.job, helpers.query)) ?? []

        // Do something...
    }
    ```
