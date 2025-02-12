import type { PoolClient } from "pg";

import { dirname, join } from "node:path";

import Postgrator from "postgrator";

const MIGRATIONS_FOLDER = join(dirname(__dirname), "migrations");

const getPostgrator = async (pgClient: PoolClient) => {
  await pgClient.query(
    /* sql */ `CREATE SCHEMA IF NOT EXISTS graphile_worker_extension`
  );

  const {
    rows: [{ currentDatabase }],
  } = await pgClient.query<{ currentDatabase: string }>(
    /* sql */ `SELECT current_database() AS "currentDatabase"`
  );

  return new Postgrator({
    driver: "pg",
    database: currentDatabase,
    migrationPattern: join(MIGRATIONS_FOLDER, "*"),
    schemaTable: "graphile_worker_extension.migrations",
    execQuery: (sql) => pgClient.query(sql),
  });
};

export const setup = async (pgClient: PoolClient) => {
  const postgrator = await getPostgrator(pgClient);

  await postgrator.migrate();
};

export const remove = async (pgClient: PoolClient) => {
  const postgrator = await getPostgrator(pgClient);

  await postgrator.migrate("0000");
};
