require 'active_record/version'
module Delayed
  module Backend
    module ActiveRecord
      # A job object that is persisted to the database.
      # Contains the work object as a YAML field.
      class Job < ::ActiveRecord::Base
        include Delayed::Backend::Base

        attr_accessible :priority, :run_at, :queue, :payload_object,
          :failed_at, :locked_at, :locked_by

        before_save :set_default_run_at

        def self.set_delayed_job_table_name
          delayed_job_table_name = "#{::ActiveRecord::Base.table_name_prefix}delayed_jobs"
          self.table_name = delayed_job_table_name
        end

        self.set_delayed_job_table_name

        def self.ready_to_run(worker_name, max_run_time)
          where('(run_at <= ? AND (locked_at IS NULL OR locked_at < ?) OR locked_by = ?) AND failed_at IS NULL', db_time_now, db_time_now - max_run_time, worker_name)
        end

        def self.by_priority
          order('priority ASC, run_at ASC')
        end

        def self.before_fork
          ::ActiveRecord::Base.clear_all_connections!
        end

        def self.after_fork
          ::ActiveRecord::Base.establish_connection
        end

        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          update_all("locked_by = null, locked_at = null", ["locked_by = ?", worker_name])
        end

        def self.reserve(worker, max_run_time = Worker.max_run_time)
          # scope to filter to records that are "ready to run"
          readyScope = self.ready_to_run(worker.name, max_run_time)

          # scope to filter to the single next eligible job (locking it for update http://www.postgresql.org/docs/9.0/static/sql-select.html#SQL-FOR-UPDATE-SHARE)
          nextScope = readyScope.scoped
          nextScope = nextScope.scoped(:conditions => ['priority >= ?', Worker.min_priority]) if Worker.min_priority
          nextScope = nextScope.scoped(:conditions => ['priority <= ?', Worker.max_priority]) if Worker.max_priority
          nextScope = nextScope.scoped(:conditions => ["queue IN (?)", Worker.queues]) if Worker.queues.any?
          nextScope = nextScope.scoped.by_priority.limit(1).lock(true)
          nextScope = nextScope.scoped.select('id')

          now = self.db_time_now

          if ::ActiveRecord::Base.connection.adapter_name == "PostgreSQL"
            # This works on PostgreSQL and uses 1 less query, but uses SQL not supported nativly through ActiveRecord
            quotedTableName = ::ActiveRecord::Base.connection.quote_column_name(self.table_name)
            reserved = self.find_by_sql(["UPDATE #{quotedTableName} SET locked_at = ?, locked_by = ? WHERE id IN (#{nextScope.to_sql}) RETURNING *",now,worker.name])
            return reserved[0]
          else
            # This works on any database and uses seperate queries to lock and return the job
            # Databases like PostgreSQL and MySQL that support "SELECT .. FOR UPDATE" (ActiveRecord Pessimistic locking) don't need the second application
            # of 'readyScope' but it doesn't hurt and it ensures that the job being locked still meets ready_to_run criteria.
            count = readyScope.where(:id => nextScope).update_all(:locked_at => now, :locked_by => worker.name)
            return nil if count == 0
            return self.where(:locked_at => now, :locked_by => worker.name).first
          end
        end

        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker)
          now = self.class.db_time_now
          affected_rows = if locked_by != worker
            # We don't own this job so we will update the locked_by name and the locked_at
            self.class.update_all(["locked_at = ?, locked_by = ?", now, worker], ["id = ? and (locked_at is null or locked_at < ?) and (run_at <= ?)", id, (now - max_run_time.to_i), now])
          else
            # We already own this job, this may happen if the job queue crashes.
            # Simply resume and update the locked_at
            self.class.update_all(["locked_at = ?", now], ["id = ? and locked_by = ?", id, worker])
          end
          if affected_rows == 1
            self.locked_at = now
            self.locked_by = worker
            self.changed_attributes.clear
            return true
          else
            return false
          end
        end

        # Get the current time (GMT or local depending on DB)
        # Note: This does not ping the DB to get the time, so all your clients
        # must have syncronized clocks.
        def self.db_time_now
          if Time.zone
            Time.zone.now
          elsif ::ActiveRecord::Base.default_timezone == :utc
            Time.now.utc
          else
            Time.now
          end
        end

        def reload(*args)
          reset
          super
        end
      end
    end
  end
end
