DROP FUNCTION :HELPERS_SCHEMA.remove_dependency_on_failure () CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.fail_parent_on_failure () CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.mark_failure () CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.cleanup_result () CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.process_job_dependency_completion_or_removal () CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.process_job_dependency_ready () CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.ignore_dependency_on_failure () CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.start_job (job_id bigint) CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.start_job (job :HELPERS_SCHEMA.job_dependencies) CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.mark_job_result_complete () CASCADE;

DROP FUNCTION :HELPERS_SCHEMA.forbid_completed_job_result_edit () CASCADE;

DROP TABLE IF EXISTS :HELPERS_SCHEMA.job_dependencies;

DROP TABLE IF EXISTS :HELPERS_SCHEMA.job_results;
