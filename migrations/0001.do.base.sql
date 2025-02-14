CREATE TABLE IF NOT EXISTS :HELPERS_SCHEMA.job_results (
  id bigint PRIMARY KEY,
  results jsonb DEFAULT NULL,
  is_complete boolean DEFAULT FALSE
);

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.forbid_completed_job_result_edit ()
  RETURNS TRIGGER
  AS $$
BEGIN
  RAISE 'Job % has already completed, result can''t be updated', OLD.id
  USING ERRCODE = 'integrity_constraint_violation';
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.mark_job_result_complete ()
  RETURNS TRIGGER
  AS $$
BEGIN
  UPDATE
    :HELPERS_SCHEMA.job_results
  SET
    is_complete = TRUE
  WHERE
    id = OLD.id;
  RETURN OLD;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER mark_job_result_complete
  AFTER DELETE ON :GRAPHILE_SCHEMA._private_jobs
  FOR EACH ROW
  EXECUTE FUNCTION :HELPERS_SCHEMA.mark_job_result_complete ();

CREATE OR REPLACE TRIGGER forbid_completed_job_result_edit
  BEFORE UPDATE ON :HELPERS_SCHEMA.job_results
  FOR EACH ROW
  WHEN (OLD.is_complete)
  EXECUTE FUNCTION :HELPERS_SCHEMA.forbid_completed_job_result_edit ();

CREATE TABLE IF NOT EXISTS :HELPERS_SCHEMA.job_dependencies (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  parent_id bigint REFERENCES :HELPERS_SCHEMA.job_dependencies (id) ON DELETE CASCADE,
  is_ready boolean DEFAULT FALSE,
  has_failed boolean DEFAULT FALSE,
  on_failure text DEFAULT 'fail-parent' ::text,
  result_id bigint REFERENCES :HELPERS_SCHEMA.job_results (id) ON DELETE CASCADE,
  identifier text NOT NULL,
  payload json DEFAULT NULL::json,
  queue_name text DEFAULT NULL::text,
  run_at timestamptz DEFAULT NULL::timestamptz,
  max_attempts integer DEFAULT NULL::integer,
  job_key text DEFAULT NULL::text,
  priority integer DEFAULT NULL::integer,
  flags text[] DEFAULT NULL::text[],
  job_key_mode text DEFAULT 'replace' ::text
);

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.start_job (
  job :HELPERS_SCHEMA.job_dependencies
)
  RETURNS void
  AS $$
DECLARE
  job_result_id :HELPERS_SCHEMA.job_results.id % type;
BEGIN
  SELECT
    id INTO job_result_id
  FROM
    :GRAPHILE_SCHEMA.add_job (job.identifier, job.payload, job.queue_name, job.run_at,
      job.max_attempts, job.job_key, job.priority, job.flags, job.job_key_mode);

  INSERT INTO :HELPERS_SCHEMA.job_results (id)
    VALUES (job_result_id);
  -- Set result ID for job
  UPDATE
    :HELPERS_SCHEMA.job_dependencies
  SET
    result_id = job_result_id
  WHERE
    id = job.id;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.start_job (
  job_id bigint
)
  RETURNS void
  AS $$
BEGIN
  PERFORM
    :HELPERS_SCHEMA.start_job (job_dependency)
  FROM
    :HELPERS_SCHEMA.job_dependencies AS job_dependency
  WHERE
    id = job_id;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.process_job_dependency_ready ()
  RETURNS TRIGGER
  AS $$
DECLARE
  in_progress_job :HELPERS_SCHEMA.job_dependencies;
BEGIN
  IF NOT EXISTS (
    SELECT
      jobs.id
    FROM
      :HELPERS_SCHEMA.job_dependencies AS jobs
    LEFT JOIN :HELPERS_SCHEMA.job_results AS results ON jobs.result_id = results.id
  WHERE
    jobs.parent_id = NEW.id
    AND (NOT jobs.is_ready
      OR NOT coalesce(results.is_complete, FALSE))) THEN
PERFORM
  :HELPERS_SCHEMA.start_job (NEW);
END IF;

  RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.process_job_dependency_completion_or_removal ()
  RETURNS TRIGGER
  AS $$
DECLARE
  parent_job_dependency :HELPERS_SCHEMA.job_dependencies;
  job_id :HELPERS_SCHEMA.job_dependencies.id % type;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    job_id = NEW.id;
    -- Remove child jobs and their results
    DELETE FROM :HELPERS_SCHEMA.job_dependencies AS dependencies USING :HELPERS_SCHEMA.job_dependencies AS parent
    WHERE parent.result_id = job_id
      AND dependencies.parent_id = parent.id;
ELSIF TG_OP = 'DELETE' THEN
  job_id = OLD.result_id;
ELSE
  RAISE 'Function :HELPERS_SCHEMA.process_job_dependency_completion_or_removal doesn''t support %s operation', TG_OP
  USING ERRCODE = 'triggered_action_exception';
END IF;
  -- Checks if some sibling jobs have yet to complete
  PERFORM
    sibling_jobs_results.id
  FROM
    :HELPERS_SCHEMA.job_dependencies AS completed_job
    INNER JOIN :HELPERS_SCHEMA.job_dependencies AS sibling_jobs USING (parent_id)
    INNER JOIN :HELPERS_SCHEMA.job_results AS sibling_jobs_results ON sibling_jobs.result_id =
      sibling_jobs_results.id
  WHERE
    completed_job.result_id = job_id
    AND NOT sibling_jobs_results.is_complete
  FOR UPDATE;
  -- If so, abort
  IF FOUND THEN
    RETURN NULL;
  END IF;

  SELECT
    parent_job.* INTO parent_job_dependency
  FROM
    :HELPERS_SCHEMA.job_dependencies AS completed_job
    INNER JOIN :HELPERS_SCHEMA.job_dependencies AS parent_job ON completed_job.parent_id = parent_job.id
  WHERE
    completed_job.result_id = job_id;

  IF parent_job_dependency IS NULL THEN
    DELETE FROM :HELPERS_SCHEMA.job_results
    WHERE id = job_id;
  ELSIF parent_job_dependency.is_ready THEN
    -- Launch parent job
    PERFORM
      :HELPERS_SCHEMA.start_job (parent_job_dependency);
  END IF;
  RETURN NULL;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.cleanup_result ()
  RETURNS TRIGGER
  AS $$
BEGIN
  DELETE FROM :HELPERS_SCHEMA.job_results
  WHERE id = OLD.result_id;
  RETURN OLD;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.mark_failure ()
  RETURNS TRIGGER
  AS $$
BEGIN
  UPDATE
    :HELPERS_SCHEMA.job_dependencies
  SET
    has_failed = TRUE
  WHERE
    result_id = NEW.id
    AND NOT has_failed;
  RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.fail_parent_on_failure ()
  RETURNS TRIGGER
  AS $$
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    DELETE FROM :HELPERS_SCHEMA.job_dependencies
    WHERE parent_id = NEW.parent_id;
    UPDATE
      :HELPERS_SCHEMA.job_dependencies
    SET
      has_failed = TRUE
    WHERE
      id = NEW.parent_id;
  END IF;
  RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.remove_dependency_on_failure ()
  RETURNS TRIGGER
  AS $$
BEGIN
  DELETE FROM :HELPERS_SCHEMA.job_dependencies
  WHERE id = NEW.id;
  PERFORM
    :GRAPHILE_SCHEMA.complete_jobs (ARRAY[NEW.result_id]);
  RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION :HELPERS_SCHEMA.ignore_dependency_on_failure ()
  RETURNS TRIGGER
  AS $$
DECLARE
  job :GRAPHILE_SCHEMA._private_jobs;
BEGIN
  PERFORM
    :GRAPHILE_SCHEMA.complete_jobs (ARRAY[NEW.result_id]);
  RETURN NEW;
END;
$$
LANGUAGE plpgsql;

-- Mark failure after the job permafail and is unlocked
CREATE OR REPLACE TRIGGER mark_failure
  AFTER UPDATE OF attempts,
  locked_at ON :GRAPHILE_SCHEMA._private_jobs
  FOR EACH ROW
  WHEN (NEW.locked_at IS NULL AND NEW.attempts = NEW.max_attempts)
  EXECUTE FUNCTION :HELPERS_SCHEMA.mark_failure ();

CREATE OR REPLACE TRIGGER fail_parent_on_failure
  AFTER UPDATE OF has_failed ON :HELPERS_SCHEMA.job_dependencies
  FOR EACH ROW
  WHEN (NOT OLD.has_failed AND NEW.has_failed AND NEW.on_failure = 'fail-parent')
  EXECUTE FUNCTION :HELPERS_SCHEMA.fail_parent_on_failure ();

CREATE OR REPLACE TRIGGER remove_dependency_on_failure
  AFTER UPDATE OF has_failed ON :HELPERS_SCHEMA.job_dependencies
  FOR EACH ROW
  WHEN (NOT OLD.has_failed AND NEW.has_failed AND NEW.on_failure = 'remove')
  EXECUTE FUNCTION :HELPERS_SCHEMA.remove_dependency_on_failure ();

CREATE OR REPLACE TRIGGER ignore_dependency_on_failure
  AFTER UPDATE OF has_failed ON :HELPERS_SCHEMA.job_dependencies
  FOR EACH ROW
  WHEN (NOT OLD.has_failed AND NEW.has_failed AND NEW.on_failure = 'ignore')
  EXECUTE FUNCTION :HELPERS_SCHEMA.ignore_dependency_on_failure ();

-- Remove job result when job dependency is removed
CREATE OR REPLACE TRIGGER cleanup_result
  AFTER DELETE ON :HELPERS_SCHEMA.job_dependencies
  EXECUTE FUNCTION :HELPERS_SCHEMA.cleanup_result ();

-- On job completion, remove children and start parent job if all sibling jobs have completed
CREATE OR REPLACE TRIGGER process_job_dependency_completion
  AFTER UPDATE OF is_complete ON :HELPERS_SCHEMA.job_results
  FOR EACH ROW
  WHEN (NEW.is_complete)
  EXECUTE FUNCTION :HELPERS_SCHEMA.process_job_dependency_completion_or_removal ();

-- On dependency removal, remove children and start parent job if all sibling jobs have completed
CREATE OR REPLACE TRIGGER process_job_dependency_removal
  AFTER DELETE ON :HELPERS_SCHEMA.job_dependencies
  FOR EACH ROW
  EXECUTE FUNCTION :HELPERS_SCHEMA.process_job_dependency_completion_or_removal ();

-- Once a dependency is ready (has all dependencies declared), start job if all children have completed
CREATE OR REPLACE TRIGGER process_job_dependency_ready
  AFTER UPDATE OF is_ready ON :HELPERS_SCHEMA.job_dependencies
  FOR EACH ROW
  WHEN (NEW.is_ready)
  EXECUTE FUNCTION :HELPERS_SCHEMA.process_job_dependency_ready ();
