# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'new_relic/agent/instrumentation/controller_instrumentation'

module NewRelic
  module Agent
    module Instrumentation
      # == Instrumentation for Rack
      #
      # New Relic will instrument a #call method as if it were a controller
      # action, collecting transaction traces and errors.  The middleware will
      # be identified only by its class, so if you want to instrument multiple
      # actions in a middleware, you need to use
      # NewRelic::Agent::Instrumentation::ControllerInstrumentation::ClassMethods#add_transaction_tracer
      #
      # Example:
      #   require 'newrelic_rpm'
      #   require 'new_relic/agent/instrumentation/rack'
      #   class Middleware
      #     def call(env)
      #       ...
      #     end
      #     # Do the include after the call method is defined:
      #     include NewRelic::Agent::Instrumentation::Rack
      #   end
      #
      # == Instrumenting Metal and Cascading Middlewares
      #
      # Metal apps and apps belonging to Rack::Cascade middleware
      # follow a convention of returning a 404 for all requests except
      # the ones they are set up to handle.  This means that New Relic
      # needs to ignore these calls when they return a 404.
      #
      # In these cases, you should not include or extend the Rack
      # module but instead include
      # NewRelic::Agent::Instrumentation::ControllerInstrumentation.
      # Here's how that might look for a Metal app:
      #
      #   require 'new_relic/agent/instrumentation/controller_instrumentation'
      #   class MetalApp
      #     extend NewRelic::Agent::Instrumentation::ControllerInstrumentation
      #     def self.call(env)
      #       if should_do_my_thing?
      #         perform_action_with_newrelic_trace(:category => :rack) do
      #           return my_response(env)
      #         end
      #       else
      #         return [404, {"Content-Type" => "text/html"}, ["Not Found"]]
      #       end
      #     end
      #   end
      #
      # == Overriding the metric name
      #
      # By default the middleware is identified only by its class, but if you want to
      # be more specific and pass in name, then omit including the Rack instrumentation
      # and instead follow this example:
      #
      #   require 'newrelic_rpm'
      #   require 'new_relic/agent/instrumentation/controller_instrumentation'
      #   class Middleware
      #     include NewRelic::Agent::Instrumentation::ControllerInstrumentation
      #     def call(env)
      #       ...
      #     end
      #     add_transaction_tracer :call, :category => :rack, :name => 'my app'
      #   end
      #
      # @api public
      #
      module Rack
        include ControllerInstrumentation

        def newrelic_request_headers
          @newrelic_request.env
        end

        def call_with_newrelic(*args)
          @newrelic_request = ::Rack::Request.new(args.first)
          perform_action_with_newrelic_trace(:category => :rack, :request => @newrelic_request) do
            result = call_without_newrelic(*args)
            # Ignore cascaded calls
            Transaction.abort_transaction! if result.first == 404
            result
          end
        end

        def self.included middleware #:nodoc:
          middleware.class_eval do
            alias call_without_newrelic call
            alias call call_with_newrelic
          end
        end

        def self.extended middleware #:nodoc:
          middleware.class_eval do
            class << self
              alias call_without_newrelic call
              alias call call_with_newrelic
            end
          end
        end
      end

      module RackBuilder
        # This method serves two, mostly independent purposes:
        #
        # 1. We trigger DependencyDetection from here, since it tends to happen
        #    late in the application startup sequence, after all libraries have
        #    actually been loaded, and libraries that may not have been loaded
        #    at the time we were originally required might be present now.
        #
        # 2. Our Rack middleware instrumentation hooks into this method in order
        #    to wrap a proxy object around each Rack middleware, and the app
        #    itself.
        #
        # Part two can be disabled with the disable_middleware_instrumentation
        # config switch. The whole thing (including parts 1 and 2) can be
        # disabled with the disable_rack config switch.
        #
        def to_app_with_newrelic_deferred_dependency_detection
          if ::NewRelic::Agent.config[:disable_middleware_instrumentation]
            ::NewRelic::Agent.logger.debug("Not using Rack::Builder instrumentation because disable_middleware_instrumentation was set in config")
          else
            if @use && @use.is_a?(Array)
              @use = RackBuilder.add_new_relic_tracing_to_middlewares(@use)
            else
              ::NewRelic::Agent.logger.warn("Not using Rack::Builder instrumentation because @use was not as expected (@use = #{@use.inspect})")
            end
          end

          unless ::Rack::Builder._nr_deferred_detection_ran
            NewRelic::Agent.logger.info "Doing deferred dependency-detection before Rack startup"
            DependencyDetection.detect!
            ::Rack::Builder._nr_deferred_detection_ran = true
          end

          to_app_without_newrelic
        end

        def self.add_new_relic_tracing_to_middlewares(middleware_procs)
          wrapped_procs = []
          last_idx = middleware_procs.size - 1

          middleware_procs.each_with_index do |middleware_proc, idx|
            wrapped_procs << Proc.new do |app|
              if idx == last_idx
                # Note that this does not double-wrap the app. If there are
                # N middlewares and 1 app, then we want N+1 wrappings. This
                # is the +1.
                app = ::NewRelic::Agent::Instrumentation::MiddlewareProxy.wrap(app, true)
              end

              result = middleware_proc.call(app)

              ::NewRelic::Agent::Instrumentation::MiddlewareProxy.wrap(result)
            end
          end
          wrapped_procs
        end
      end
    end
  end
end

DependencyDetection.defer do
  named :rack

  depends_on do
    defined?(::Rack) && defined?(::Rack::Builder)
  end

  executes do
    ::NewRelic::Agent.logger.info 'Installing deferred Rack instrumentation'
  end

  executes do
    class ::Rack::Builder
      class << self
        attr_accessor :_nr_deferred_detection_ran
      end
      self._nr_deferred_detection_ran = false

      include ::NewRelic::Agent::Instrumentation::RackBuilder

      alias_method :to_app_without_newrelic, :to_app
      alias_method :to_app, :to_app_with_newrelic_deferred_dependency_detection
    end
  end
end

