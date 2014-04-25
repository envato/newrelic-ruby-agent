# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'new_relic/agent/transaction_timings'
require 'new_relic/agent/instrumentation/queue_time'

module NewRelic
  module Agent
    # This class represents a single transaction (usually mapping to one
    # web request or background job invocation) instrumented by the Ruby agent.
    #
    # @api public
    class Transaction

      attr_accessor :start_time  # A Time instance for the start time, never nil
      attr_accessor :apdex_start # A Time instance used for calculating the apdex score, which
      # might end up being @start, or it might be further upstream if
      # we can find a request header for the queue entry time
      attr_accessor :type, :exceptions, :filtered_params,
                    :jruby_cpu_start, :process_cpu_start, :database_metric_name

      attr_reader :name
      attr_reader :guid
      attr_reader :stats_hash
      attr_reader :gc_start_snapshot

      # Populated with the trace sample once this transaction is completed.
      attr_reader :transaction_trace

      # Give the current transaction a request context.  Use this to
      # get the URI and referer.  The request is interpreted loosely
      # as a Rack::Request or an ActionController::AbstractRequest.
      attr_accessor :request

      # Return the currently active transaction, or nil.
      def self.current
        self.stack.last
      end

      def self.parent
        self.stack[-2]
      end

      def self.start(transaction_type, options={})
        txn = Transaction.new(transaction_type, options)
        txn.start(transaction_type, options)
        self.stack.push(txn)
        return txn
      end

      def self.stop(end_time=Time.now, opts={})
        txn = self.stack.last
        txn.stop(end_time, opts) if txn
        return self.stack.pop
      end

      def self.stack
        TransactionState.get.current_transaction_stack
      end

      def self.in_transaction?
        !self.stack.empty?
      end

      def parent
        has_parent? && self.class.stack[-2]
      end

      def root?
        self.class.stack.size == 1
      end

      def has_parent?
        self.class.stack.size > 1
      end

      # This is the name of the model currently assigned to database
      # measurements, overriding the default.
      def self.database_metric_name
        current && current.database_metric_name
      end

      def self.referer
        current && current.referer
      end

      def self.agent
        NewRelic::Agent.instance
      end

      def self.freeze_name_and_execute_if_not_ignored
        self.current && self.current.freeze_name_and_execute_if_not_ignored { yield if block_given? }
      end

      @@java_classes_loaded = false

      if defined? JRuby
        begin
          require 'java'
          java_import 'java.lang.management.ManagementFactory'
          java_import 'com.sun.management.OperatingSystemMXBean'
          @@java_classes_loaded = true
        rescue
        end
      end

      attr_reader :depth

      def initialize(type=nil, options={})
        @name = options[:transaction_name] || NewRelic::Agent::UNKNOWN_METRIC
        @type = type || :controller
        @start_time = Time.now
        @apdex_start = options[:apdex_start_time] || @start_time
        @jruby_cpu_start = jruby_cpu_time
        @process_cpu_start = process_cpu
        @gc_start_snapshot = NewRelic::Agent::StatsEngine::GCProfiler.take_snapshot
        @filtered_params = options[:filtered_params] || {}
        @request = options[:request]
        @exceptions = {}
        @stats_hash = StatsHash.new
        @guid = generate_guid
        @ignore_this_transaction = false
        TransactionState.get.most_recent_transaction = self
      end

      def noticed_error_ids
        @noticed_error_ids ||= []
      end

      def name=(name)
        if !@name_frozen
          @name = Helper.correctly_encoded(name)
        else
          NewRelic::Agent.logger.warn("Attempted to rename transaction to '#{name}' after transaction name was already frozen as '#{@name}'.")
        end
      end

      def name_set?
        @name && @name != NewRelic::Agent::UNKNOWN_METRIC
      end

      def freeze_name_and_execute_if_not_ignored
        if !name_frozen?
          name = NewRelic::Agent.instance.transaction_rules.rename(@name)
          @name_frozen = true

          if name.nil?
            @ignore_this_transaction = true
          else
            @name = name
          end
        end

        if block_given? && !@ignore_this_transaction
          yield
        end
      end

      def name_frozen?
        @name_frozen
      end

      def ignored?
        @ignore_this_transaction
      end

      # Indicate that we are entering a measured controller action or task.
      # Make sure you unwind every push with a pop call.
      def start(transaction_type, txn_options)
        transaction_sampler.on_start_transaction(start_time, uri, filtered_params)
        sql_sampler.on_start_transaction(start_time, uri, filtered_params)
        NewRelic::Agent.instance.events.notify(:start_transaction)
        NewRelic::Agent::BusyCalculator.dispatcher_start(start_time)

        @trace_options = {
                    :force                        => txn_options[:force],
                    :metric                       => true,
                    :transaction                  => true,
                    :deduct_call_time_from_parent => true
                  }
        _, @expected_scope = NewRelic::Agent::MethodTracer::TraceExecutionScoped.trace_execution_scoped_header(@trace_options, start_time.to_f)
      end

      # Indicate that you don't want to keep the currently saved transaction
      # information
      def self.abort_transaction!
        current.abort_transaction! if current
      end

      # For the current web transaction, return the path of the URI minus the host part and query string, or nil.
      def uri
        @uri ||= self.class.uri_from_request(@request) unless @request.nil?
      end

      # For the current web transaction, return the full referer, minus the host string, or nil.
      def referer
        @referer ||= self.class.referer_from_request(@request)
      end

      # Call this to ensure that the current transaction is not saved
      def abort_transaction!
        transaction_sampler.ignore_transaction
      end

      def summary_metrics
        if has_parent?
          []
        else
          metric_parser = NewRelic::MetricParser::MetricParser.for_metric_named(@name)
          metric_parser.summary_metrics
        end
      end

      # Unwind one stack level.  It knows if it's back at the outermost caller and
      # does the appropriate wrapup of the context.
      def stop(end_time=Time.now, opts={})
        freeze_name_and_execute_if_not_ignored

        NewRelic::Agent::MethodTracer::TraceExecutionScoped.trace_execution_scoped_footer(
          start_time.to_f,
          @name,
          summary_metrics,
          @expected_scope,
          @trace_options,
          end_time.to_f)

        log_underflow if @type.nil?
        NewRelic::Agent::BusyCalculator.dispatcher_finish(end_time)

        freeze_name_and_execute_if_not_ignored do
          # these record metrics so need to be done before merging stats
          if self.root?
            # this one records metrics and wants to happen
            # before the transaction sampler is finished
            if NewRelic::Agent.is_execution_traced?
              record_transaction_cpu
              gc_stop_snapshot = NewRelic::Agent::StatsEngine::GCProfiler.take_snapshot
              gc_delta = NewRelic::Agent::StatsEngine::GCProfiler.record_delta(
                  gc_start_snapshot, gc_stop_snapshot)
            end
            @transaction_trace = transaction_sampler.on_finishing_transaction(self, Time.now, gc_delta)
            sql_sampler.on_finishing_transaction(@name)

            record_apdex(end_time, opts[:exception_encountered]) unless opts[:ignore_apdex]
            NewRelic::Agent::Instrumentation::QueueTime.record_frontend_metrics(apdex_start, start_time) if queue_time > 0.0
            NewRelic::Agent::TransactionState.get.request_ignore_enduser = true if opts[:ignore_enduser]
          end

          record_exceptions
          merge_stats_hash

          send_transaction_finished_event(start_time, end_time) if self.root?
        end
      end

      # This event is fired when the transaction is fully completed. The metric
      # values and sampler can't be successfully modified from this event.
      def send_transaction_finished_event(start_time, end_time)
        payload = {
          :name             => @name,
          :type             => @type,
          :start_timestamp  => start_time.to_f,
          :duration         => end_time.to_f - start_time.to_f,
          :metrics          => @stats_hash,
          :custom_params    => custom_parameters
        }
        append_guid_to(payload)
        append_referring_transaction_guid_to(payload)

        agent.events.notify(:transaction_finished, payload)
      end

      def append_guid_to(payload)
        guid = NewRelic::Agent::TransactionState.get.request_guid_for_event
        if guid
          payload[:guid] = guid
        end
      end

      def append_referring_transaction_guid_to(payload)
        referring_guid = NewRelic::Agent.instance.cross_app_monitor.client_referring_transaction_guid
        if referring_guid
          payload[:referring_transaction_guid] = referring_guid
        end
      end

      def log_underflow
        NewRelic::Agent.logger.error "Underflow in transaction: #{caller.join("\n   ")}"
      end

      def merge_stats_hash
        stats_hash.resolve_scopes!(@name)
        NewRelic::Agent.instance.stats_engine.merge!(stats_hash)
      end

      def record_exceptions
        @exceptions.each do |exception, options|
          options[:metric] = @name
          agent.error_collector.notice_error(exception, options)
        end
      end

      # If we have an active transaction, notice the error and increment the error metric.
      # Options:
      # * <tt>:request</tt> => Request object to get the uri and referer
      # * <tt>:uri</tt> => The request path, minus any request params or query string.
      # * <tt>:referer</tt> => The URI of the referer
      # * <tt>:metric</tt> => The metric name associated with the transaction
      # * <tt>:request_params</tt> => Request parameters, already filtered if necessary
      # * <tt>:custom_params</tt> => Custom parameters
      # Anything left over is treated as custom params

      def self.notice_error(e, options={})
        options = extract_request_options(options)
        if current
          current.notice_error(e, options)
        else
          options = extract_finished_transaction_options(options)
          agent.error_collector.notice_error(e, options)
        end
      end

      def self.extract_request_options(options)
        req = options.delete(:request)
        if req
          options[:referer] = referer_from_request(req)
          options[:uri] = uri_from_request(req)
        end
        options
      end

      # If we aren't currently in a transaction, but found the remains of one
      # just finished in the TransactionState, use those custom params!
      def self.extract_finished_transaction_options(options)
        finished_txn = NewRelic::Agent::TransactionState.get.most_recent_transaction
        if finished_txn
          custom_params = options.fetch(:custom_params, {})
          custom_params.merge!(finished_txn.custom_parameters)
          options = options.merge(:custom_params => custom_params)
          options[:metric] = finished_txn.name
        end
        options
      end

      # Do not call this.  Invoke the class method instead.
      def notice_error(e, options={}) # :nodoc:
        options[:referer] = referer if referer
        options[:request_params] = filtered_params if filtered_params
        options[:uri] = uri if uri
        options.merge!(custom_parameters)
        if !@exceptions.keys.include?(e)
          @exceptions[e] = options
        end
      end

      # Add context parameters to the transaction.  This information will be passed in to errors
      # and transaction traces.  Keys and Values should be strings, numbers or date/times.
      def self.add_custom_parameters(p)
        current.add_custom_parameters(p) if current
      end

      def self.custom_parameters
        (current && current.custom_parameters) ? current.custom_parameters : {}
      end

      class << self
        alias_method :user_attributes, :custom_parameters
        alias_method :set_user_attributes, :add_custom_parameters
      end

      APDEX_METRIC_SPEC = NewRelic::MetricSpec.new('Apdex').freeze

      def record_apdex(end_time=Time.now, is_error=nil)
        return unless recording_web_transaction? && NewRelic::Agent.is_execution_traced?

        freeze_name_and_execute_if_not_ignored do
          action_duration = end_time - start_time
          total_duration  = end_time - apdex_start
          is_error = is_error.nil? ? !exceptions.empty? : is_error

          apdex_bucket_global = self.class.apdex_bucket(total_duration,  is_error, apdex_t)
          apdex_bucket_txn    = self.class.apdex_bucket(action_duration, is_error, apdex_t)

          @stats_hash.record(APDEX_METRIC_SPEC, apdex_bucket_global, apdex_t)
          txn_apdex_metric = NewRelic::MetricSpec.new(@name.gsub(/^[^\/]+\//, 'Apdex/'))
          @stats_hash.record(txn_apdex_metric, apdex_bucket_txn, apdex_t)
        end
      end

      def apdex_t
        transaction_specific_apdex_t || Agent.config[:apdex_t]
      end

      def transaction_specific_apdex_t
        key = :web_transactions_apdex
        Agent.config[key] && Agent.config[key][self.name]
      end

      # Yield to a block that is run with a database metric name context.  This means
      # the Database instrumentation will use this for the metric name if it does not
      # otherwise know about a model.  This is re-entrant.
      #
      # * <tt>model</tt> is the DB model class
      # * <tt>method</tt> is the name of the finder method or other method to identify the operation with.
      #
      def with_database_metric_name(model, method)
        previous = @database_metric_name
        model_name = case model
                     when Class
                       model.name
                     when String
                       model
                     else
                       model.to_s
                     end
        @database_metric_name = "ActiveRecord/#{model_name}/#{method}"
        yield
      ensure
        @database_metric_name=previous
      end

      def custom_parameters
        @custom_parameters ||= {}
      end

      def add_custom_parameters(p)
        custom_parameters.merge!(p)
      end

      alias_method :user_attributes, :custom_parameters
      alias_method :set_user_attributes, :add_custom_parameters

      def queue_time
        @apdex_start ? @start_time - @apdex_start : 0
      end

      # Returns truthy if the current in-progress transaction is considered a
      # a web transaction (as opposed to, e.g., a background transaction).
      #
      # @api public
      #
      def self.recording_web_transaction?
        self.current && self.current.recording_web_transaction?
      end

      def self.transaction_type_is_web?(type)
        [:controller, :uri, :rack, :sinatra].include?(type)
      end

      def recording_web_transaction?
        self.class.transaction_type_is_web?(@type)
      end

      # Make a safe attempt to get the referer from a request object, generally successful when
      # it's a Rack request.
      def self.referer_from_request(req)
        if req && req.respond_to?(:referer)
          req.referer.to_s.split('?').first
        end
      end

      # Make a safe attempt to get the URI, without the host and query string.
      def self.uri_from_request(req)
        approximate_uri = case
                          when req.respond_to?(:fullpath   ) then req.fullpath
                          when req.respond_to?(:path       ) then req.path
                          when req.respond_to?(:request_uri) then req.request_uri
                          when req.respond_to?(:uri        ) then req.uri
                          when req.respond_to?(:url        ) then req.url
                          end
        return approximate_uri[%r{^(https?://.*?)?(/[^?]*)}, 2] || '/' if approximate_uri
      end



      def self.record_apdex(end_time, is_error)
        current && current.record_apdex(end_time, is_error)
      end

      def self.apdex_bucket(duration, failed, apdex_t)
        case
        when failed
          :apdex_f
        when duration <= apdex_t
          :apdex_s
        when duration <= 4 * apdex_t
          :apdex_t
        else
          :apdex_f
        end
      end

      def cpu_burn
        normal_cpu_burn || jruby_cpu_burn
      end

      def normal_cpu_burn
        return unless @process_cpu_start
        process_cpu - @process_cpu_start
      end

      def jruby_cpu_burn
        return unless @jruby_cpu_start
        jruby_cpu_time - @jruby_cpu_start
      end

      def record_transaction_cpu
        burn = cpu_burn
        transaction_sampler.notice_transaction_cpu_time(burn) if burn
      end

      private

      def process_cpu
        return nil if defined? JRuby
        p = Process.times
        p.stime + p.utime
      end

      def jruby_cpu_time
        return nil unless @@java_classes_loaded
        threadMBean = ManagementFactory.getThreadMXBean()
        java_utime = threadMBean.getCurrentThreadUserTime()  # ns
        -1 == java_utime ? 0.0 : java_utime/1e9
      end

      def agent
        NewRelic::Agent.instance
      end

      def transaction_sampler
        agent.transaction_sampler
      end

      def sql_sampler
        agent.sql_sampler
      end

      HEX_DIGITS = (0..15).map{|i| i.to_s(16)}
      GUID_LENGTH = 16

      # generate a random 64 bit uuid
      def generate_guid
        guid = ''
        GUID_LENGTH.times do |a|
          guid << HEX_DIGITS[rand(16)]
        end
        guid
      end

    end
  end
end
