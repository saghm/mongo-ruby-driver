# Copyright (C) 2014-2019 MongoDB, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Mongo
  class Server
    class ConnectionPool

      # A LIFO queue of connections to be used by the connection pool. This is
      # based on mperham's connection pool.
      #
      # @note The queue contains active connections that are available for
      #   use. It does not track connections which are in use (checked out).
      #   It is easy to confuse the size of the connection pool (number of
      #   connections that are used plus number of connections that are
      #   available for use) and the size of the queue (number of connections
      #   that have already been created that are available for use).
      #   API documentation for this class states whether each size refers
      #   to the pool or to the queue size. Note that minimum and maximum
      #   sizes only make sense when talking about the connection pool,
      #   as the size of the queue of available connections is determined by
      #   the size constraints of the pool plus how many connections are
      #   currently checked out.
      #
      # @since 2.0.0
      class Queue
        include Loggable
        include Monitoring::Publishable
        extend Forwardable

        # The default max size for the connection pool.
        MAX_SIZE = 5.freeze

        # The default min size for the connection pool.
        MIN_SIZE = 1.freeze

        # The default timeout, in seconds, to wait for a connection.
        WAIT_TIMEOUT = 1.freeze

        # Initialize the new queue. Will yield the block the number of times
        # equal to the initial connection pool size.
        #
        # @example Create the queue.
        #   Mongo::Server::ConnectionPool::Queue.new(address, monitoring, max_pool_size: 5) do
        #     Connection.new
        #   end
        #
        # @option options [ Integer ] :max_pool_size The maximum pool size.
        # @option options [ Integer ] :min_pool_size The minimum pool size.
        # @option options [ Float ] :wait_queue_timeout The time to wait, in
        #   seconds, for a free connection.
        #
        # @since 2.0.0
        def initialize(address, monitoring, options = {}, &block)
          @address = address
          @monitoring = monitoring

          if options[:min_pool_size] && options[:max_pool_size] &&
            options[:min_pool_size] > options[:max_pool_size]
          then
            raise ArgumentError, "Cannot have min size > max size"
          end
          @block = block
          # This is the number of connections in the pool.
          # Includes available connections in the queue and the checked
          # out connections that we don't otherwise track.
          @pool_size = 0
          @options = options
          @generation = 1
          if min_size > max_size
            raise ArgumentError, "min_size (#{min_size}) cannot exceed max_size (#{max_size})"
          end
          @queue = Array.new(min_size) { create_connection }
          @mutex = Mutex.new
          @resource = ConditionVariable.new

          @wait_queue = []
          @wait_queue_mutex = Mutex.new

          check_count_invariants
        end

        # @return [ Integer ] generation Generation of connections currently
        #   being used by the queue.
        #
        # @since 2.7.0
        # @api private
        attr_reader :generation

        # @return [ Array ] queue The underlying array of connections.
        attr_reader :queue

        # @return [ Mutex ] mutex The mutex used for synchronization.
        attr_reader :mutex

        # @return [ Hash ] options The options.
        attr_reader :options

        # @return [ ConditionVariable ] resource The resource.
        attr_reader :resource

        # Number of connections that the pool has which are ready to be
        # checked out. This is NOT the size of the connection pool (total
        # number of active connections created by the pool).
        def_delegators :queue, :size

        # Number of connections that the pool has which are ready to be
        # checked out.
        #
        # @since 2.7.0
        alias_method :queue_size, :size

        # Number of connections in the pool (active connections ready to
        # be checked out plus connections already checked out).
        #
        # @since 2.7.0
        attr_reader :pool_size

        # Retrieves a connection. If there are active connections in the
        # queue, the most recently used connection is returned. Otherwise
        # if the connection pool size is less than the max size, creates a
        # new connection and returns it. Otherwise raises Timeout::Error.
        #
        # @example Dequeue a connection.
        #   queue.dequeue
        #
        # @return [ Mongo::Server::Connection ] The next connection.
        # @raise [ Timeout::Error ] If the connection pool is at maximum size
        #   and remains so for longer than the wait timeout.
        #
        # @since 2.0.0
        def dequeue
          check_count_invariants(false)
          dequeue_connection
        ensure
          check_count_invariants(false)
          @wait_queue_mutex.synchronize do
            @wait_queue.shift
          end
        end

        # Updates the generation number. The connections will be disconnected and removed lazily
        # when the queue attempts to dequeue them.
        #
        # @since 2.7.0
        def clear!
          @generation += 1
        end

        # Disconnect all connections in the queue.
        #
        # @example Disconnect all connections.
        #   queue.disconnect!
        #
        # @return [ true ] Always true.
        #
        # @since 2.1.0
        def disconnect!
          check_count_invariants(false)
          mutex.synchronize do
            queue.each do |connection|
              @pool_size -= 1
              if @pool_size < 0
                # This should never happen
                log_warn("ConnectionPool::Queue: connection accounting problem")
                @pool_size = 0
              end

              connection.disconnect!

              publish_cmap_event(
                  Monitoring::Event::ConnectionClosed.new(
                      Monitoring::Event::ConnectionClosed::POOL_CLOSED,
                      @address,
                      connection.id,
                  ),
              )
            end

            queue.clear
            @generation += 1
            while @pool_size < min_size
              @pool_size += 1
              queue.unshift(@block.call(@generation))
            end
            true
          end
        ensure
          check_count_invariants
        end

        # Enqueue a connection in the queue.
        #
        # Only connections created by this queue should be enqueued
        # back into it, however the queue does not verify whether it
        # originally created the connection being enqueued.
        #
        # If linting is enabled (see Mongo::Lint), attempting to enqueue
        # connections beyond the pool's capacity will raise Mongo::Error::LintError
        # (since some of those connections must not have originated from
        # the queue into which they are being enqueued). If linting is
        # not enabled, the queue can grow beyond its max size with undefined
        # results.
        #
        # @example Enqueue a connection.
        #   queue.enqueue(connection)
        #
        # @param [ Mongo::Server::Connection ] connection The connection.
        #
        # @since 2.0.0
        def enqueue(connection)
          check_count_invariants(false)
          mutex.synchronize do
            if connection.generation == @generation
              queue.unshift(connection.record_checkin!)
              resource.broadcast
              @wait_queue_mutex.synchronize do
                @wait_queue.first.broadcast unless @wait_queue.empty?
              end
            else
              close_connection!(connection, Monitoring::Event::ConnectionClosed::STALE)
            end
          end
          nil
        ensure
          check_count_invariants(false)
        end

        # Get a pretty printed string inspection for the queue.
        #
        # @example Inspect the queue.
        #   queue.inspect
        #
        # @return [ String ] The queue inspection.
        #
        # @since 2.0.0
        def inspect
          "#<Mongo::Server::ConnectionPool::Queue:0x#{object_id} min_size=#{min_size} max_size=#{max_size} " +
            "wait_timeout=#{wait_timeout} current_size=#{queue_size}>"
        end

        # Get the maximum size of the connection pool.
        #
        # @example Get the max size.
        #   queue.max_size
        #
        # @return [ Integer ] The maximum size of the connection pool.
        #
        # @since 2.0.0
        def max_size
          @max_size ||= options[:max_pool_size] || [MAX_SIZE, min_size].max
        end

        # Get the minimum size of the connection pool.
        #
        # @example Get the min size.
        #   queue.min_size
        #
        # @return [ Integer ] The minimum size of the connection pool.
        #
        # @since 2.0.0
        def min_size
          @min_size ||= options[:min_pool_size] || MIN_SIZE
        end

        # The time to wait, in seconds, for a connection to become available.
        #
        # @example Get the wait timeout.
        #   queue.wait_timeout
        #
        # @return [ Float ] The queue wait timeout.
        #
        # @since 2.0.0
        def wait_timeout
          @wait_timeout ||= options[:wait_queue_timeout] || WAIT_TIMEOUT
        end

        # The maximum seconds a socket can remain idle since it has been
        # checked in to the pool.
        #
        # @example Get the max idle time.
        #   queue.max_idle_time
        #
        # @return [ Float ] The max socket idle time in seconds.
        #
        # @since 2.5.0
        def max_idle_time
          @max_idle_time ||= options[:max_idle_time]
        end

        # Close sockets that have been open for longer than the max idle time,
        #   if the option is set.
        #
        # @example Close the stale sockets
        #   queue.close_stale_sockets!
        #
        # @since 2.5.0
        def close_stale_sockets!
          check_count_invariants(false)
          return unless max_idle_time

          to_refresh = []
          queue.each do |connection|
            if last_checkin = connection.last_checkin
              if (Time.now - last_checkin) > max_idle_time
                to_refresh << connection
              end
            end
          end

          mutex.synchronize do
            num_checked_out = pool_size - queue_size
            min_size_delta = [(min_size - num_checked_out), 0].max

            to_refresh.each do |connection|
              if queue.include?(connection)
                connection.disconnect!
                if queue.index(connection) < min_size_delta
                  begin; connection.connect!; rescue; end
                end
              end
            end
          end
        ensure
          check_count_invariants(false)
        end

        private

        def close_connection!(connection, reason)
          @pool_size -= 1
          if @pool_size < 0
            # This should never happen
            log_warn("ConnectionPool::Queue: unexpected enqueue")
            @pool_size = 0
          end

          connection.disconnect!

          publish_cmap_event(
            Monitoring::Event::ConnectionClosed.new(
              reason,
              @address,
              connection.id,
            )
          )
        end

        def is_stale?(connection)
          if connection.generation != @generation
            close_connection!(connection, Monitoring::Event::ConnectionClosed::STALE)
            true
          end
        end

        def is_idle?(connection)
          if connection && connection.last_checkin && max_idle_time
            if Time.now - connection.last_checkin > max_idle_time
              close_connection!(connection, Monitoring::Event::ConnectionClosed::IDLE)
              true
            end
          end
        end

        def dequeue_connection
          semaphore = check_wait_queue
          deadline = Time.now + wait_timeout
          semaphore.wait(wait_timeout) if semaphore
          raise Error::WaitQueueTimeout.new(@address, pool_size) if deadline <= Time.now

          mutex.synchronize do
            loop do
              until queue.empty?
                connection = queue.shift

                unless is_stale?(connection) || is_idle?(connection)
                  return connection
                end
              end

              connection = create_connection
              return connection if connection

              wait = deadline - Time.now
              resource.wait(mutex, wait)
              raise Error::WaitQueueTimeout.new(@address, pool_size) if deadline <= Time.now
            end
          end
        end

        def check_wait_queue
          semaphore = Semaphore.new

          @wait_queue_mutex.synchronize do
            @wait_queue << semaphore

            # No need to wait for semaphore if nothing else is in the wait queue.
            if @wait_queue.size == 1
              return
            end
          end


          semaphore
        end

        def create_connection
          if pool_size < max_size
            @pool_size += 1
            @block.call(@generation)
          end
        end

        # We only create new connections when we're below the minPoolSize on creation, when we're
        # disconnecting and starting a new generation, and when we're checking out connections (per
        # the CMAP spec), so `check_min` should be false in all other cases.
        def check_count_invariants(check_min = true)
          if Mongo::Lint.enabled?
            if pool_size < min_size && check_min
              raise Error::LintError, 'connection pool queue: underflow'
            end
            if pool_size > max_size
              raise Error::LintError, 'connection pool queue: overflow'
            end
          end
        end
      end
    end
  end
end
