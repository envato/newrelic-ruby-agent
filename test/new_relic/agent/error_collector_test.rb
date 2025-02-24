# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.
# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../data_container_tests'
require 'new_relic/agent/internal_agent_error'

module NewRelic::Agent
  class ErrorCollector
    class ErrorCollectorTest < Minitest::Test
      def setup
        @test_config = {
          :capture_params => true,
          :disable_harvest_thread => true
        }
        NewRelic::Agent.config.add_config_for_testing(@test_config)

        events = NewRelic::Agent.instance.events
        @error_collector = NewRelic::Agent::ErrorCollector.new(events)
        @error_collector.stubs(:enabled).returns(true)

        NewRelic::Agent::Tracer.clear_state
        NewRelic::Agent.instance.stats_engine.reset!
      end

      def teardown
        super
        NewRelic::Agent::ErrorCollector.ignore_error_filter = nil
        NewRelic::Agent::Tracer.clear_state
        NewRelic::Agent.config.reset_to_defaults
      end

      # Tests

      def test_empty
        @error_collector.notice_error(nil, :metric => 'path')
        traces = harvest_error_traces
        events = harvest_error_events

        assert_equal 0, traces.length
        assert_equal 0, events.length
      end

      def test_records_error_outside_of_transaction
        in_transaction do
          @error_collector.notice_error(StandardError.new)
        end
        traces = harvest_error_traces
        events = harvest_error_events

        assert_equal 1, traces.length
        assert_equal 1, events.length
      end

      def test_exclude
        @error_collector.ignore(['IOError'])

        @error_collector.notice_error(IOError.new('message'), :metric => 'path')

        traces = harvest_error_traces
        events = harvest_error_events

        assert_equal 0, traces.length
        assert_equal 0, events.length
      end

      def test_exclude_later_config_changes
        in_transaction do
          @error_collector.notice_error(IOError.new('message'))
        end

        NewRelic::Agent.config.add_config_for_testing(:'error_collector.ignore_classes' => ['IOError'])

        in_transaction do
          @error_collector.notice_error(IOError.new('message'))
        end

        traces = harvest_error_traces
        events = harvest_error_events

        assert_equal 1, traces.length
        assert_equal 1, events.length
      end

      def test_exclude_block
        @error_collector.class.ignore_error_filter = wrapped_filter_proc

        in_transaction do
          @error_collector.notice_error(IOError.new('message'), :metric => 'path')
          @error_collector.notice_error(StandardError.new('message'), :metric => 'path')
        end

        traces = harvest_error_traces
        events = harvest_error_events

        assert_equal 1, traces.length
        assert_equal 1, events.length
      end

      def test_failure_in_exclude_block
        @error_collector.class.ignore_error_filter = proc do
          raise 'HAHAHAHAH, error in the filter for ignoring errors!'
        end

        in_transaction do
          @error_collector.notice_error(StandardError.new('message'))
        end

        traces = harvest_error_traces
        events = harvest_error_events

        assert_equal 1, traces.length
        assert_equal 1, events.length
      end

      def test_failure_block_assigned_with_different_instance
        @error_collector.class.ignore_error_filter = proc do |*_|
          # meh, ignore 'em all!
          nil
        end

        new_error_collector = NewRelic::Agent::ErrorCollector.new(NewRelic::Agent.instance.events)
        new_error_collector.notice_error(StandardError.new('message'))

        assert_empty new_error_collector.error_trace_aggregator.harvest!
      end

      def test_increments_count_on_errors
        @error_collector.notice_error(StandardError.new('Boo'))

        assert_metrics_recorded(
          'Errors/all' => {:call_count => 1}
        )

        @error_collector.notice_error(StandardError.new('Boo'))

        assert_metrics_recorded(
          'Errors/all' => {:call_count => 2}
        )
      end

      def test_increment_error_count_record_summary_and_web_txn_metric
        in_web_transaction('Controller/class/method') do
          @error_collector.increment_error_count!(NewRelic::Agent::Tracer.state, StandardError.new('Boo'))
        end

        assert_metrics_recorded(['Errors/all',
          'Errors/allWeb',
          'Errors/Controller/class/method'])
      end

      def test_increment_error_count_record_summary_and_other_txn_metric
        in_background_transaction('OtherTransaction/AnotherFramework/Job/perform') do
          @error_collector.increment_error_count!(NewRelic::Agent::Tracer.state, StandardError.new('Boo'))
        end

        assert_metrics_recorded(['Errors/all',
          'Errors/allOther',
          'Errors/OtherTransaction/AnotherFramework/Job/perform'])
      end

      def test_increment_error_count_summary_outside_transaction
        @error_collector.increment_error_count!(NewRelic::Agent::Tracer.state, StandardError.new('Boo'))

        assert_metrics_recorded(['Errors/all'])
        assert_metrics_not_recorded(['Errors/allWeb', 'Errors/allOther'])
      end

      def test_doesnt_increment_error_count_on_transaction_if_nameless
        @error_collector.increment_error_count!(NewRelic::Agent::Tracer.state,
          StandardError.new('Boo'),
          :metric => '(unknown)')

        assert_metrics_not_recorded(['Errors/(unknown)'])
      end

      def test_blamed_metric_from_options_outside_txn
        @error_collector.notice_error(StandardError.new('wut'), :metric => 'boo')

        assert_metrics_recorded(
          'Errors/boo' => {:call_count => 1}
        )
      end

      def test_blamed_metric_from_options_inside_txn
        in_transaction('Not/What/Youre/Looking/For') do
          @error_collector.notice_error(StandardError.new('wut'), :metric => 'boo')
        end

        assert_metrics_recorded_exclusive(
          {
            'Errors/all' => {:call_count => 1},
            'Errors/boo' => {:call_count => 1},
            'Errors/allOther' => {:call_count => 1}
          },
          :filter => /^Errors\//
        )
      end

      def test_blamed_metric_from_transaction
        in_transaction('Controller/foo/bar') do
          @error_collector.notice_error(StandardError.new('wut'))
        end

        assert_metrics_recorded(
          'Errors/Controller/foo/bar' => {:call_count => 1}
        )
      end

      def test_blamed_metric_with_no_transaction_and_no_options
        @error_collector.notice_error(StandardError.new('wut'))

        assert_metrics_recorded_exclusive(['Errors/all'])
      end

      def test_doesnt_double_count_same_exception
        in_transaction do
          error = StandardError.new('wat')
          @error_collector.notice_error(error)
          @error_collector.notice_error(error)
        end

        errors = @error_collector.error_trace_aggregator.harvest!

        assert_metrics_recorded('Errors/all' => {:call_count => 1})
        assert_equal 1, errors.length
      end

      def test_doesnt_count_seen_exceptions
        in_transaction do
          error = StandardError.new('wat')
          @error_collector.tag_exception(error)
          @error_collector.notice_error(error)
        end

        errors = @error_collector.error_trace_aggregator.harvest!

        assert_metrics_not_recorded(['Errors/all'])
        assert_empty errors
      end

      def test_captures_attributes_on_notice_error
        error = StandardError.new('wat')
        attributes = Object.new
        @error_collector.notice_error(error, :attributes => attributes)

        errors = @error_collector.error_trace_aggregator.harvest!
        noticed = errors.first

        assert_equal attributes, noticed.attributes
      end

      module Winner
        def winner
          'yay'
        end
      end

      def test_sense_method
        object = Object.new
        object.extend(Winner)

        assert_nil @error_collector.sense_method(object, 'blab')
        assert_equal 'yay', @error_collector.sense_method(object, 'winner')
      end

      def test_extract_stack_trace
        assert_equal('<no stack trace>', @error_collector.extract_stack_trace(Exception.new))
      end

      def test_trace_truncated_with_config
        with_config(:'error_collector.max_backtrace_frames' => 2) do
          trace = @error_collector.truncate_trace(%w[error1 error2 error3 error4])

          assert_equal ['error1', '<truncated 2 additional frames>', 'error4'], trace
        end
      end

      def test_trace_truncated_with_nil_config
        with_config(:'error_collector.max_backtrace_frames' => nil) do
          trace = @error_collector.truncate_trace(%w[error1 error2 error3 error4])

          assert_equal 4, trace.length
        end
      end

      def test_short_trace_not_truncated
        trace = @error_collector.truncate_trace(%w[error error error], 6)

        assert_equal 3, trace.length
      end

      def test_empty_trace_not_truncated
        trace = @error_collector.truncate_trace([], 7)

        assert_empty trace
      end

      def test_keeps_correct_frames_if_keep_frames_is_even
        trace = @error_collector.truncate_trace(%w[error1 error2 error3 error4], 2)

        assert_equal ['error1', '<truncated 2 additional frames>', 'error4'], trace
      end

      def test_keeps_correct_frames_if_keep_frames_is_odd
        trace = @error_collector.truncate_trace(%w[error1 error2 error3 error4], 3)

        assert_equal ['error1', 'error2', '<truncated 1 additional frames>', 'error4'], trace
      end

      if defined?(Rails::VERSION::MAJOR) && Rails::VERSION::MAJOR < 5
        def test_extract_stack_trace_from_original_exception
          orig = mock('original', :backtrace => 'STACK STACK STACK')
          exception = mock('exception', :original_exception => orig)

          assert_equal('STACK STACK STACK', @error_collector.extract_stack_trace(exception))
        end
      end

      def test_skip_notice_error_is_true_if_the_error_collector_is_disabled
        error = StandardError.new
        server_source = {
          :'error_collector.enabled' => false,
          :'error_collector.capture_events' => false
        }

        with_server_source(server_source) do
          assert @error_collector.skip_notice_error?(error)
        end
      end

      def test_skip_notice_error_is_true_if_the_error_is_nil
        error = nil

        with_config(:'error_collector.enabled' => true) do
          assert @error_collector.skip_notice_error?(error)
        end
      end

      def test_skip_notice_error_is_true_if_the_error_is_ignored
        error = StandardError.new
        with_config(:'error_collector.enabled' => true) do
          @error_collector.expects(:error_is_ignored?).with(error, nil).returns(true)

          assert @error_collector.skip_notice_error?(error)
        end
      end

      def test_skip_notice_error_returns_false_for_non_nil_unignored_errors_with_an_enabled_error_collector
        error = StandardError.new
        with_config(:'error_collector.enabled' => true) do
          @error_collector.expects(:error_is_ignored?).with(error, nil).returns(false)

          refute @error_collector.skip_notice_error?(error)
        end
      end

      class ::AnError
      end

      def test_ignored_and_expected_error_is_ignored
        with_config(:'error_collector.ignore_classes' => ['AnError'],
          :'error_collector.expected_classes' => ['AnError']) do
          @error_collector.notice_error(AnError.new)

          events = harvest_error_events

          assert_equal 0, events.length
        end
      end

      def test_ignore_status_codes
        error = AnError.new

        with_config(:'error_collector.ignore_status_codes' => '400-408') do
          assert @error_collector.ignore?(error, 404)
        end
      end

      def test_filtered_by_error_filter_empty
        # should return right away when there's no filter
        refute @error_collector.ignored_by_filter_proc?(nil)
      end

      def test_filtered_by_error_filter_positive
        saw_error = nil
        NewRelic::Agent::ErrorCollector.ignore_error_filter = proc do |e|
          saw_error = e
          false
        end

        error = StandardError.new

        assert @error_collector.ignored_by_filter_proc?(error)

        assert_equal error, saw_error
      end

      def test_filtered_by_error_filter_negative
        saw_error = nil
        NewRelic::Agent::ErrorCollector.ignore_error_filter = proc do |e|
          saw_error = e
          true
        end

        error = StandardError.new

        refute @error_collector.ignored_by_filter_proc?(error)

        assert_equal error, saw_error
      end

      def test_error_is_ignored_no_error
        refute @error_collector.error_is_ignored?(nil)
      end

      def test_does_not_tag_frozen_errors
        e = StandardError.new
        e.freeze
        @error_collector.notice_error(e)

        refute @error_collector.exception_tagged_with?(EXCEPTION_TAG_IVAR, e)
      end

      def test_handles_failures_during_error_tagging
        e = StandardError.new
        e.stubs(:instance_variable_set).raises(RuntimeError)
        expects_logging(:warn, any_parameters)

        @error_collector.notice_error(e)
      end

      if NewRelic::LanguageSupport.jruby?
        def test_does_not_tag_java_objects
          e = java.lang.String.new
          @error_collector.notice_error(e)

          refute @error_collector.exception_tagged_with?(EXCEPTION_TAG_IVAR, e)
        end
      end

      def test_expected_error_sets_expected_attribute_to_true
        in_transaction do
          @error_collector.notice_error(StandardError.new, :expected => true)
        end
        traces = harvest_error_traces
        events = harvest_error_events
        event_attrs = events[0][0]
        trace_attrs = traces[0].to_collector_array[4]

        assert event_attrs['error.expected'], "Event attributes should have 'error.expected' set to true"
        assert trace_attrs[:'error.expected'], "Trace attributes should have 'error.expected' set to true"
      end

      def test_unexpected_error_sets_expected_attribute_to_false
        in_transaction do
          @error_collector.notice_error(StandardError.new)
        end
        traces = harvest_error_traces
        events = harvest_error_events
        event_attrs = events[0][0]
        trace_attrs = traces[0].to_collector_array[4]

        # nil isn't good enough!
        refute event_attrs['error.expected'], "Intrinsic attributes should have 'error.expected' set to false"
        refute trace_attrs[:'error.expected'], "Trace attributes should have 'error.expected' set to false"
      end

      def test_expected_error_does_not_increment_metrics
        in_transaction do
          @error_collector.notice_error(StandardError.new, :expected => true)
        end
        traces = harvest_error_traces
        events = harvest_error_events

        assert_equal 1, traces.length
        assert_equal 1, events.length
        assert_metrics_not_recorded ['Errors/all']
        assert_metrics_recorded ['ErrorsExpected/all']
      end

      def test_expected_error_not_recorded_as_custom_attribute
        in_transaction do
          @error_collector.notice_error(StandardError.new, :expected => true)
        end
        traces = harvest_error_traces
        events = harvest_error_events

        assert_equal 1, traces.length
        assert_equal 1, events.length

        event_attrs = events[0][1]

        refute event_attrs.key?('expected'), 'Unexpected attribute expected found in custom attributes'

        trace_attrs = traces[0].attributes_from_notice_error

        refute trace_attrs.key?(:expected), 'Unexpected attribute expected found in custom attributes'
      end

      def test_segment_error_attributes
        with_segment do |segment|
          @error_collector.notice_segment_error(segment, StandardError.new('Oops!'))

          assert segment.noticed_error, 'expected segment.noticed_error to not be nil'

          # we defer building the error attributes until segments are turned into spans!
          assert_equal NewRelic::EMPTY_HASH, segment.noticed_error.attributes_from_notice_error

          # now, let's build and see the error attributes
          segment.noticed_error.build_error_attributes
          recorded_error_attributes = SpanEventPrimitive.error_attributes(segment)

          expected_error_attributes = {
            'error.message' => 'Oops!',
            'error.class' => 'StandardError'
          }

          assert_equal expected_error_attributes, segment.noticed_error.attributes_from_notice_error
          assert_equal expected_error_attributes, recorded_error_attributes
        end

        assert_nothing_harvested_for_segment_errors
      end

      def test_segment_error_attributes_for_expected_error
        with_segment do |segment|
          @error_collector.notice_segment_error(segment, StandardError.new('Oops!'), {expected: true})

          assert segment.noticed_error, 'expected segment.noticed_error to not be nil'

          # we defer building the error attributes until segments are turned into spans!
          assert_equal NewRelic::EMPTY_HASH, segment.noticed_error.attributes_from_notice_error

          # now, let's build and see the error attributes
          segment.noticed_error.build_error_attributes
          recorded_error_attributes = SpanEventPrimitive.error_attributes(segment)

          expected_error_attributes = {
            'error.message' => 'Oops!',
            'error.class' => 'StandardError',
            'error.expected' => true
          }

          assert_equal expected_error_attributes, segment.noticed_error.attributes_from_notice_error
          assert_equal expected_error_attributes, recorded_error_attributes
        end

        assert_nothing_harvested_for_segment_errors
      end

      def test_segment_error_attributes_for_tx_notice_error_api_call
        with_segment do |segment|
          NewRelic::Agent::Transaction.notice_error(StandardError.new('Oops!'), {expected: true})

          assert segment.noticed_error, 'expected segment.noticed_error to not be nil'

          # we defer building the error attributes until segments are turned into spans!
          assert_equal NewRelic::EMPTY_HASH, segment.noticed_error.attributes_from_notice_error

          # now, let's build and see the error attributes
          segment.noticed_error.build_error_attributes
          recorded_error_attributes = SpanEventPrimitive.error_attributes(segment)

          expected_error_attributes = {
            'error.message' => 'Oops!',
            'error.class' => 'StandardError',
            'error.expected' => true
          }

          assert_equal expected_error_attributes, segment.noticed_error.attributes_from_notice_error
          assert_equal expected_error_attributes, recorded_error_attributes
        end

        assert_nothing_harvested_for_segment_errors
      end

      def test_segment_error_filtered
        with_config(:'error_collector.ignore_classes' => ['StandardError']) do
          with_segment do |segment|
            @error_collector.notice_segment_error(segment, StandardError.new('Oops!'))

            refute segment.noticed_error, 'expected segment.noticed_error to be nil'
          end
        end

        assert_nothing_harvested_for_segment_errors
      end

      def test_segment_error_exclude_block
        @error_collector.class.ignore_error_filter = wrapped_filter_proc

        with_segment do |segment|
          @error_collector.notice_segment_error(segment, IOError.new('message'))

          refute segment.noticed_error, 'expected segment.noticed_error to be nil'
        end

        assert_nothing_harvested_for_segment_errors
      end

      def test_build_customer_callback_hash
        custom_attributes = {billie_eilish: :bored}
        agent_attributes = {'http.statusCode': :bleachers__dont_take_the_money}
        intrinsic_attributes = {'http.method': :walk_the_moon__anna_sun}
        request_uri = :alternative_music
        options = {taylor_swift: :maroon}
        expected = true
        error = StandardError.new

        noticed_error = NewRelic::NoticedError.new(:watermelon, error)
        noticed_error.instance_variable_set(:@processed_attributes,
          {NewRelic::NoticedError::USER_ATTRIBUTES => custom_attributes,
           NewRelic::NoticedError::AGENT_ATTRIBUTES => agent_attributes,
           NewRelic::NoticedError::INTRINSIC_ATTRIBUTES => intrinsic_attributes})
        noticed_error.request_uri = request_uri
        noticed_error.expected = expected
        hash = @error_collector.send(:build_customer_callback_hash, noticed_error, error, options)

        assert_equal hash[:error], error
        assert_equal hash[:customAttributes], custom_attributes
        assert_equal hash[:'request.uri'], request_uri
        assert_equal hash[:'http.statusCode'], agent_attributes[:'http.statusCode']
        assert_equal hash[:'http.method'], intrinsic_attributes[:'http.method']
        assert_equal hash[:'error.expected'], expected
        assert_equal hash[:options], options
      end

      def test_update_error_group_name_returns_nil_unless_a_callback_has_been_registered
        # because the build_customer_callback_hash method will call
        # #custom_attributes on the noticed error object, and we're passing in
        # nil for it, it would error out if the early return we're testing for
        # did not return
        @error_collector.stub(:error_group_callback, nil) do
          assert_nil @error_collector.send(:update_error_group_name, nil, nil, nil)
        end
      end

      def test_update_error_group_name_updates_the_error_group_name
        error = ArgumentError.new
        error_group = 'lucky tiger'
        noticed_error = NewRelic::NoticedError.new(:watermelon, error)
        NewRelic::Agent.set_error_group_callback(proc { |hash| error_group if hash[:error].is_a?(ArgumentError) })
        @error_collector.send(:update_error_group_name, noticed_error, error, {})

        assert_equal error_group, noticed_error.error_group
      ensure
        NewRelic::Agent.remove_instance_variable(:@error_group_callback)
      end

      def test_update_error_group_logs_if_an_error_is_rescued
        skip_unless_minitest5_or_above

        logger = MiniTest::Mock.new
        # have #error return a phony value just for the purpose of being able
        # to supply this test with at least 1 assertion. really, the #verify
        # call to the mock should suffice, but it's nice to have assertions
        phony_return = :yep_i_was_indeed_called
        logger.expect :error, phony_return, [/Failed to obtain/]
        @error_collector.stub(:error_group_callback, -> { raise 'kaboom' }) do
          NewRelic::Agent.stub :logger, logger do
            assert_equal phony_return, @error_collector.send(:update_error_group_name, nil, nil, nil)
          end
        end
        logger.verify
      end

      def test_noticed_errors_have_the_error_group_present_in_their_agent_attributes
        error_group = 'blackcurrant tea'
        exception = RuntimeError.new
        NewRelic::Agent.set_error_group_callback(proc { |hash| error_group if hash[:error].is_a?(RuntimeError) })
        noticed_error = @error_collector.create_noticed_error(exception, {})

        assert_equal error_group, noticed_error.agent_attributes[::NewRelic::NoticedError::AGENT_ATTRIBUTE_ERROR_GROUP]
      ensure
        NewRelic::Agent.remove_instance_variable(:@error_group_callback)
      end

      private

      # Segment errors utilize the error_collector's filtering for LASP
      # but should not otherwise trigger queuing for harvesting and count metrics
      def assert_nothing_harvested_for_segment_errors
        traces = harvest_error_traces
        events = harvest_error_events

        assert_equal 0, traces.length
        assert_equal 0, events.length
      end

      def wrapped_filter_proc
        proc do |e|
          if e.is_a?(IOError)
            return nil
          else
            return e
          end
        end
      end

      def harvest_error_traces
        @error_collector.error_trace_aggregator.harvest!
      end

      def harvest_error_events
        @error_collector.error_event_aggregator.harvest![1]
      end
    end
  end
end
