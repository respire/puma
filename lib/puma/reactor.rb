require 'puma/util'
require 'puma/minissl'

module Puma
  class Reactor
    DefaultSleepFor = 5

    def initialize(server, app_pool)
      @server = server
      @events = server.events
      @app_pool = app_pool

      @mutex = Mutex.new
      @ready, @trigger = Puma::Util.pipe
      @mutex_for_pipe = Mutex.new # Guard pipe
      @input = []
      @sleep_for = DefaultSleepFor
      @timeouts = []

      @sockets = [@ready]
    end

    private

    def pipe_closed?
      @mutex_for_pipe.synchronize do
        @trigger.closed? || @trigger.fileno < 0 || @ready.closed? || @ready.fileno < 0
      end
    end

    def close_pipe
      @mutex_for_pipe.synchronize do
        begin
          @trigger.close unless @trigger.closed? || @trigger.fileno < 0
          @ready.close unless @ready.closed? || @ready.fileno < 0
        rescue IOError
          retry
        end
      end
    end

    def run_internal
      sockets = @sockets

      while true
        return if pipe_closed?

        begin
          ready = IO.select sockets, nil, nil, @sleep_for
        rescue IOError => e
          if sockets.any? { |socket| socket.closed? && socket != @ready }
            unless STDERR.closed? || STDERR.fileno < 0
              STDERR.puts "Error in select: #{e.message} (#{e.class})"
              STDERR.puts e.backtrace
            end
            sockets = sockets.reject { |socket| socket.closed? }
            retry
          elsif pipe_closed?
            return
          else
            raise
          end
        end

        if ready and reads = ready[0]
          reads.each do |c|
            if c == @ready
              @mutex.synchronize do
                case @ready.read(1)
                when "*"
                  sockets += @input
                  @input.clear
                when "c"
                  sockets.delete_if do |s|
                    if s == @ready
                      false
                    else
                      s.close
                      true
                    end
                  end
                when "!"
                  return
                end
              end
            else
              # We have to be sure to remove it from the timeout
              # list or we'll accidentally close the socket when
              # it's in use!
              if c.timeout_at
                @mutex.synchronize do
                  @timeouts.delete c
                end
              end

              begin
                if c.try_to_finish
                  @app_pool << c
                  sockets.delete c
                end

              # Don't report these to the lowlevel_error handler, otherwise
              # will be flooding them with errors when persistent connections
              # are closed.
              rescue ConnectionError
                c.write_500
                c.close

                sockets.delete c

              # SSL handshake failure
              rescue MiniSSL::SSLError => e
                @server.lowlevel_error(e, c.env)

                ssl_socket = c.io
                addr = ssl_socket.peeraddr.last
                cert = ssl_socket.peercert

                c.close
                sockets.delete c

                @events.ssl_error @server, addr, cert, e

              # The client doesn't know HTTP well
              rescue HttpParserError => e
                @server.lowlevel_error(e, c.env)

                c.write_400
                c.close

                sockets.delete c

                @events.parse_error @server, c.env, e
              rescue StandardError => e
                @server.lowlevel_error(e, c.env)

                c.write_500
                c.close

                sockets.delete c
              end
            end
          end
        end

        unless @timeouts.empty?
          @mutex.synchronize do
            now = Time.now

            while @timeouts.first.timeout_at < now
              c = @timeouts.shift
              c.write_408 if c.in_data_phase
              c.close
              sockets.delete c

              break if @timeouts.empty?
            end

            calculate_sleep
          end
        end
      end
    end

    public

    def run
      run_internal
    ensure
      close_pipe
    end

    def run_in_thread
      @thread = Thread.new do
        begin
          run_internal
        rescue StandardError => e
          unless STDERR.closed? || STDERR.fileno < 0
            STDERR.puts "Error in reactor loop escaped: #{e.message} (#{e.class})"
            STDERR.puts e.backtrace
          end
          retry unless pipe_closed?
        ensure
          close_pipe
        end
      end
    end

    def calculate_sleep
      if @timeouts.empty?
        @sleep_for = DefaultSleepFor
      else
        diff = @timeouts.first.timeout_at.to_f - Time.now.to_f

        if diff < 0.0
          @sleep_for = 0
        else
          @sleep_for = diff
        end
      end
    end

    def add(c)
      @mutex.synchronize do
        @input << c
        @trigger << "*"

        if c.timeout_at
          @timeouts << c
          @timeouts.sort! { |a,b| a.timeout_at <=> b.timeout_at }

          calculate_sleep
        end
      end
    end

    def thread_safe_trigger(cmd)
      @mutex_for_pipe.synchronize do
        begin
          @trigger << cmd unless @trigger.closed? || @trigger.fileno < 0 || @ready.closed? || @ready.fileno < 0
        rescue IOError
        end
      end
    end

    # Close all watched sockets and clear them from being watched
    def clear!
      Thread.new { thread_safe_trigger 'c' }.join
    end

    def shutdown
      Thread.new { thread_safe_trigger '!' }.join

      @thread.join
    end
  end
end
