module ZK
  module ZKEventMachine
    # @example use of on_connecting
    #
    #   def handle_connecting_event(event=nil)
    #
    #     # this (re-)registers this hook for the next time this event is called
    #     @zkem.on_connecting(&:handle_connecting_event)
    #
    #     return unless event     # nil is the initial registration case
    #
    #     logger.warn { "Oh no! got a connecting event, taking evasive action!" }
    #
    #     # do stuff
    #   end
    #
    #
    #   # your setup method would then look like
    #   def run
    #     @zkem.connect do
    #       handle_connecting_event
    #       
    #       do_the_rest_of_your_stuff
    #     end
    #   end
    #
    class Client < ZK::Client::Base
      include Deferred::Accessors
      include ZK::Logging
      include Unixisms

      DEFAULT_TIMEOUT = 10

      # If we get a ZK::Exceptions::ConnectionLoss exeption back from any call,
      # or a EXPIRED_SESSION_STATE event, we will call back any handlers registered
      # here with the exception instance as the argument.
      #
      # once this deferred has been fired, it will be replaced with a new
      # deferred, so callbacks must be re-registered, and *should* be
      # re-registered *within* the callback to avoid missing events
      #
      # @note if you want to be notified when the connection state has not
      #   become *invalid* but you are in a possibly recoverable state, then
      #   you should hook the {#on_connecting} method
      # 
      # @method on_connection_lost
      # @return [Deferred::Default]
      deferred_event :connection_lost

      # Registers a one-shot callback for the ZOO_CONNECTED_STATE event. 
      #
      # @note this is experimental currently. This may or may not fire for the *initial* connection.
      # it's purpose is to warn an already-existing client with watches that a connection has been
      # re-established (with session information saved). From the ZooKeeper Programmers' Guide:
      #
      #   If you are using watches, you must look for the connected watch event.
      #   When a ZooKeeper client disconnects from a server, you will not receive
      #   notification of changes until reconnected. If you are watching for a
      #   znode to come into existance, you will miss the event if the znode is
      #   created and deleted while you are disconnected.
      #
      # once this deferred has been fired, it will be replaced with a new
      # deferred, so callbacks must be re-registered, and *should* be
      # re-registered *within* the callback to avoid missing events
      #
      # @method on_connected
      # @return [Deferred::Default]
      deferred_event :connected

      # Registers a one-shot callback for the ZOO_CONNECTING_STATE event
      #
      # This event is triggered when we have become disconnected from the
      # cluster and are in the process of reconnecting.
      # 
      # @note this would more accurately be called `on_disconnection`, but because
      #   it's fired also when the client is starting up, it has the name it does.
      #   there's an alias for this `on_disconnection`. (It's not `on_disconnected`
      #   because the '-ion' seems to indicate that the condition may be temporary)
      #
      # @method on_connecting
      # @return [Deferred::Default]
      deferred_event :connecting

      alias :on_disconnection :on_connecting

      # called back once the connection has been closed.
      #
      # @method on_close
      # @return [Deferred::Default]
      deferred_event :close

      # Takes same options as ZK::Client::Base
      def initialize(host, opts={})
        @host = host
        @event_handler  = EventHandlerEM.new(self)
        @closing        = false
        register_default_event_handlers!
      end

      # @private
      def closing?
        !!@closing
      end

      # open a ZK connection, attach it to the reactor. 
      # returns an EM::Deferrable that will be called when the connection is
      # ready for use
      def connect(&blk)
        # XXX: maybe move this into initialize, need to figure out how to schedule it properly
        @cnx ||= (
          ZookeeperEM::Client.new(@host, DEFAULT_TIMEOUT, event_handler.get_default_watcher_block)
        )
        @cnx.on_attached(&blk)
      end

      # @private
      def reopen(*a)
        raise NotImplementedError, "reoopen is not implemented for the eventmachine version of the client"
      end
      
      def close!(&blk)
        on_close(&blk)
        return on_close if @closing
        @closing = true

        if @cnx
          logger.debug { "#{self.class.name}: in close! clearing event_handler" }
          event_handler.clear!

          logger.debug { "#{self.class.name}: calling @cnx.close" }
          @cnx.close do
            logger.debug { "firing on_close handler" }
            on_close.succeed
            @cnx = nil
          end
        else
          on_close.succeed
        end

        on_close
      end
      alias :close :close!

      # get data at path, optionally enabling a watch on the node
      #
      # @return [Callback] returns a Callback which is an EM::Deferred (so you
      #   can assign callbacks/errbacks) see Callback::Base for discussion
      #
      def get(path, opts={}, &block)
        Callback.new_get_cb(block) do |cb|
          cb.errback(&method(:connection_lost_hook))
          cb.context = { :method => __method__, :path => path, :opts => opts }
          super(path, opts.merge(:callback => cb))
        end
      end

      def create(path, data='', opts={}, &block)
        Callback.new_create_cb(block) do |cb|
          cb.errback(&method(:connection_lost_hook))
          cb.context = { :method => __method__, :path => path, :data => data, :opts => opts }
          super(path, data, opts.merge(:callback => cb))
        end
      end

      def set(path, data, opts={}, &block)
        Callback.new_set_cb(block) do |cb|
          cb.errback(&method(:connection_lost_hook))
          cb.context = { :method => __method__, :path => path, :data => data, :opts => opts }
          super(path, data, opts.merge(:callback => cb))
        end
      end

      def stat(path, opts={}, &block)
        cb_style = opts.delete(:cb_style) { |_| 'stat' }

        meth = :"new_#{cb_style}_cb"

        Callback.__send__(meth, block) do |cb|
          cb.errback(&method(:connection_lost_hook))
          cb.context = { :method => __method__, :path => path, :meth => meth, :opts => opts }
          super(path, opts.merge(:callback => cb))
        end
      end

      def exists?(path, opts={}, &block)
        stat(path, opts.merge(:cb_style => 'exists'), &block)
      end

      def delete(path, opts={}, &block)
        Callback.new_delete_cb(block) do |cb|
          cb.errback(&method(:connection_lost_hook))
          cb.context = { :method => __method__, :path => path, :opts => opts }
          super(path, opts.merge(:callback => cb))
        end
      end

      def children(path, opts={}, &block)
        Callback.new_children_cb(block) do |cb|
          cb.errback(&method(:connection_lost_hook))
          cb.context = { :method => __method__, :path => path, :opts => opts }
          super(path, opts.merge(:callback => cb))
        end
      end

      def get_acl(path, opts={}, &block)
        Callback.new_get_acl_cb(block) do |cb|
          cb.errback(&method(:connection_lost_hook))
          cb.context = { :method => __method__, :path => path, :opts => opts }
          super(path, opts.merge(:callback => cb))
        end
      end

      def set_acl(path, acls, opts={}, &block)
        Callback.new_set_acl_cb(block) do |cb|
          cb.errback(&method(:connection_lost_hook))
          cb.context = { :method => __method__, :path => path, :acls => acls, :opts => opts }
          super(path, acls, opts.merge(:callback => cb))
        end
      end

      # @return [Fixnum] The underlying connection's session_id
      def session_id
        return nil unless @cnx
        @cnx.session_id
      end

      # @return [String] The underlying connection's session passwd (an opaque value)
      def session_passwd
        return nil unless @cnx
        @cnx.session_passwd
      end

      # Used by the event_handler to deliver callbacks. This hopefully won't
      # have any other side-effects, as it's not happening on a separate
      # thread, rather just in the next reactor tick.
      #
      # @private
      def defer
        EM.next_tick { yield }
      end

    protected
      # @private
      def register_default_event_handlers!
        @event_handler.register_state_handler(Zookeeper::ZOO_EXPIRED_SESSION_STATE, &method(:handle_expired_session_state_event!))
        @event_handler.register_state_handler(Zookeeper::ZOO_CONNECTED_STATE,       &method(:handle_connected_state_event!))
        @event_handler.register_state_handler(Zookeeper::ZOO_CONNECTING_STATE,      &method(:handle_connecting_state_event!))
      end

      # @private
      def handle_connected_state_event!(event)
        EM.schedule { reset_connected_event.succeed(event) }
      end

      # @private
      def handle_connecting_state_event!(event)
        EM.schedule { reset_connecting_event.succeed(event) }
      end

      # @private
      def handle_expired_session_state_event!(event)
        exc = ZK::Exceptions::ConnectionLoss.new("Received EXPIRED_SESSION_STATE event: #{event.inspect}")
        exc.set_backtrace(caller)
        connection_lost_hook(exc)
      end

      # @private
      def connection_lost_hook(exc)
        if exc and exc.kind_of?(ZK::Exceptions::ConnectionLoss)
          EM.schedule { reset_connection_lost_event.succeed(exc) }
        end
      end
    end
  end
end

