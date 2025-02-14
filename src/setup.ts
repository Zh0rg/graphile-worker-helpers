import type { PoolClient } from "pg"

import { dirname, join } from "node:path"

import Postgrator from "postgrator"

const MIGRATIONS_FOLDER = join(dirname(__dirname), "migrations")
const DEFAULT_SCHEMA = "graphile_worker_helpers"
const DEFAULT_GRAPHILE_SCHEMA = "graphile_worker"

interface SchemaOptions {
  helpersSchema?: string
  graphileSchema?: string
}

const getPostgrator = async (pgClient: PoolClient, schemas?: SchemaOptions) => {
  const helpersSchema = schemas?.helpersSchema ?? DEFAULT_SCHEMA
  const escapedSchema = pgClient.escapeIdentifier(helpersSchema)

  await pgClient.query(/* sql */ `CREATE SCHEMA IF NOT EXISTS ${escapedSchema}`)

  const {
    rows: [{ currentDatabase }],
  } = await pgClient.query<{ currentDatabase: string }>(
    /* sql */ `SELECT current_database() AS "currentDatabase"`
  )

  return new Postgrator({
    driver: "pg",
    database: currentDatabase,
    migrationPattern: join(MIGRATIONS_FOLDER, "*"),
    schemaTable: `${helpersSchema}.migrations`,
    execQuery: (sql) =>
      pgClient.query(
        sql
          .replaceAll(
            ":GRAPHILE_SCHEMA",
            pgClient.escapeIdentifier(
              schemas?.graphileSchema ?? DEFAULT_GRAPHILE_SCHEMA
            )
          )
          .replaceAll(":HELPERS_SCHEMA", escapedSchema)
      ),
  })
}

export const setup =
  (schemas?: SchemaOptions) => async (pgClient: PoolClient) => {
    const postgrator = await getPostgrator(pgClient, schemas)

    await postgrator.migrate()
  }

export const remove =
  (schemas?: SchemaOptions) => async (pgClient: PoolClient) => {
    const postgrator = await getPostgrator(pgClient, schemas)

    await postgrator.migrate("0000")

    await pgClient.query(
      /* sql */ `DROP SCHEMA ${pgClient.escapeIdentifier(
        schemas?.helpersSchema ?? DEFAULT_SCHEMA
      )} CASCADE`
    )
  }
