require 'socket'

# = Statsd: A DogStatsd client (https://www.datadoghq.com)
#
# @example Set up a global Statsd client for a server on localhost:8125
#   require 'statsd'
#   $statsd = Statsd.new 'localhost', 8125
# @example Send some stats
#   $statsd.increment 'page.views'
#   $statsd.timing 'page.load', 320
#   $statsd.gauge 'users.online', 100
# @example Use {#time} to time the execution of a block
#   $statsd.time('account.activate') { @account.activate! }
# @example Create a namespaced statsd client and increment 'account.activate'
#   statsd = Statsd.new 'localhost', 8125, :namespace => 'account'
#   statsd.increment 'activate'
# @example Create a statsd client with global tags
#   statsd = Statsd.new 'localhost', 8125, :tags => 'tag1:true'
class Statsd

  DEFAULT_HOST = '127.0.0.1'
  DEFAULT_PORT = 8125

  # A namespace to prepend to all statsd calls. Defaults to no namespace.
  attr_reader :namespace

  # StatsD host. Defaults to 127.0.0.1.
  attr_reader :host

  # StatsD port. Defaults to 8125.
  attr_reader :port

  # Global tags to be added to every statsd call. Defaults to no tags.
  attr_reader :tags

  class << self
    # Set to a standard logger instance to enable debug logging.
    attr_accessor :logger
  end

  # Return the current version of the library.
  def self.VERSION
    "1.2.0"
  end

  # @param [String] host your statsd host
  # @param [Integer] port your statsd port
  # @option opts [String] :namespace set a namespace to be prepended to every metric name
  # @option opts [Array<String>] :tags tags to be added to every metric
  def initialize(host = DEFAULT_HOST, port = DEFAULT_PORT, opts = {})
    self.host, self.port = host, port
    @prefix = nil
    @socket = UDPSocket.new
    self.namespace = opts[:namespace]
    self.tags = opts[:tags]
  end

  def namespace=(namespace) #:nodoc:
    @namespace = namespace
    @prefix = namespace.nil? ? nil : "#{namespace}."
  end

  def host=(host) #:nodoc:
    @host = host || '127.0.0.1'
  end

  def port=(port) #:nodoc:
    @port = port || 8125
  end

  def tags=(tags) #:nodoc:
    @tags = tags || []
  end

  # Sends an increment (count = 1) for the given stat to the statsd server.
  #
  # @param [String] stat stat name
  # @param [Hash] opts the options to create the metric with
  # @option opts [Numeric] :sample_rate sample rate, 1 for always
  # @option opts [Array<String>] :tags An array of tags
  # @see #count
  def increment(stat, opts={})
    count stat, 1, opts
  end

  # Sends a decrement (count = -1) for the given stat to the statsd server.
  #
  # @param [String] stat stat name
  # @param [Hash] opts the options to create the metric with
  # @option opts [Numeric] :sample_rate sample rate, 1 for always
  # @option opts [Array<String>] :tags An array of tags
  # @see #count
  def decrement(stat, opts={})
    count stat, -1, opts
  end

  # Sends an arbitrary count for the given stat to the statsd server.
  #
  # @param [String] stat stat name
  # @param [Integer] count count
  # @param [Hash] opts the options to create the metric with
  # @option opts [Numeric] :sample_rate sample rate, 1 for always
  # @option opts [Array<String>] :tags An array of tags
  def count(stat, count, opts={})
    send_stats stat, count, :c, opts
  end

  # Sends an arbitary gauge value for the given stat to the statsd server.
  #
  # This is useful for recording things like available disk space,
  # memory usage, and the like, which have different semantics than
  # counters.
  #
  # @param [String] stat stat name.
  # @param [Numeric] value gauge value.
  # @param [Hash] opts the options to create the metric with
  # @option opts [Numeric] :sample_rate sample rate, 1 for always
  # @option opts [Array<String>] :tags An array of tags
  # @example Report the current user count:
  #   $statsd.gauge('user.count', User.count)
  def gauge(stat, value, opts={})
    send_stats stat, value, :g, opts
  end

  # Sends a value to be tracked as a histogram to the statsd server.
  #
  # @param [String] stat stat name.
  # @param [Numeric] value histogram value.
  # @param [Hash] opts the options to create the metric with
  # @option opts [Numeric] :sample_rate sample rate, 1 for always
  # @option opts [Array<String>] :tags An array of tags
  # @example Report the current user count:
  #   $statsd.histogram('user.count', User.count)
  def histogram(stat, value, opts={})
    send_stats stat, value, :h, opts
  end

  # Sends a timing (in ms) for the given stat to the statsd server. The
  # sample_rate determines what percentage of the time this report is sent. The
  # statsd server then uses the sample_rate to correctly track the average
  # timing for the stat.
  #
  # @param [String] stat stat name
  # @param [Integer] ms timing in milliseconds
  # @param [Hash] opts the options to create the metric with
  # @option opts [Numeric] :sample_rate sample rate, 1 for always
  # @option opts [Array<String>] :tags An array of tags
  def timing(stat, ms, opts={})
    send_stats stat, ms, :ms, opts
  end

  # Reports execution time of the provided block using {#timing}.
  #
  # @param [String] stat stat name
  # @param [Hash] opts the options to create the metric with
  # @option opts [Numeric] :sample_rate sample rate, 1 for always
  # @option opts [Array<String>] :tags An array of tags
  # @yield The operation to be timed
  # @see #timing
  # @example Report the time (in ms) taken to activate an account
  #   $statsd.time('account.activate') { @account.activate! }
  def time(stat, opts={})
    start = Time.now
    result = yield
    timing(stat, ((Time.now - start) * 1000).round, opts)
    result
  end
  # Sends a value to be tracked as a set to the statsd server.
  #
  # @param [String] stat stat name.
  # @param [Numeric] value set value.
  # @param [Hash] opts the options to create the metric with
  # @option opts [Numeric] :sample_rate sample rate, 1 for always
  # @option opts [Array<String>] :tags An array of tags
  # @example Record a unique visitory by id:
  #   $statsd.set('visitors.uniques', User.id)
  def set(stat, value, opts={})
    send_stats stat, value, :s, opts
  end

  # This end point allows you to post events to the stream. You can tag them, set priority and even aggregate them with other events.
  #
  # Aggregation in the stream is made on hostname/event_type/source_type/aggregation_key.
  # If there's no event type, for example, then that won't matter;
  # it will be grouped with other events that don't have an event type.
  #
  # @param [String] title Event title
  # @param [String] text Event text. Supports \n
  # @param [Hash] opts the additional data about the event
  # @option opts [Time, nil] :date_happened (nil) Assign a timestamp to the event. Default is now when none
  # @option opts [String, nil] :hostname (nil) Assign a hostname to the event.
  # @option opts [String, nil] :aggregation_key (nil) Assign an aggregation key to the event, to group it with some others
  # @option opts [String, nil] :priority ('normal') Can be "normal" or "low"
  # @option opts [String, nil] :source_type_name (nil) Assign a source type to the event
  # @option opts [String, nil] :alert_type ('info') Can be "error", "warning", "info" or "success".
  # @option opts [Array<String>, nil] :source_type_name (nil) An array of tags
  # @example Report an aweful event:
  #   $statsd.event('Something terrible happened', 'The end is near if we do nothing', :alert_type=>'warning', :tags=>['end_of_times','urgent'])
  def event(title, text, opts={})
    escape_event_content title
    escape_event_content text
    event_string_data = "_e{#{title.length},#{text.length}}:#{title}|#{text}"

    date_happened = opts[:date_happened] || nil
    event_string_data << "|d:#{date_happened}" if date_happened

    hostname = opts[:hostname] || nil
    event_string_data << "|h:#{hostname}" if hostname

    aggregation_key = opts[:aggregation_key] || nil
    event_string_data << "|k:#{aggregation_key}" if aggregation_key

    priority = opts[:priority] || nil
    event_string_data << "|p:#{priority}" if priority

    source_type_name = opts[:source_type_name] || nil
    event_string_data << "|s:#{source_type_name}" if source_type_name

    alert_type = opts[:alert_type] || nil
    event_string_data << "|t:#{alert_type}" if alert_type

    tags = opts[:tags] || nil
    if tags
      tags = "#{tags.join(",")}" unless tags.empty?
      event_string_data << "|##{tags}"
    end

    raise "Event #{title} payload is too big (more that 8KB), event discarded" if event_string_data.length > 8 * 1024

    send_to_socket event_string_data
  end

  private

  def escape_event_content(msg)
    msg = msg.to_s.gsub("\n", "\\n")
  end

  def send_stats(stat, delta, type, opts={})
    sample_rate = opts[:sample_rate] || 1
    if sample_rate == 1 or rand < sample_rate
      # Replace Ruby module scoping with '.' and reserved chars (: | @) with underscores.
      stat = stat.to_s.gsub('::', '.').tr(':|@', '_')
      rate = "|@#{sample_rate}" unless sample_rate == 1
      ts = (tags || []) + (opts[:tags] || [])
      tags = "|##{ts.join(",")}" unless ts.empty?
      send_to_socket "#{@prefix}#{stat}:#{delta}|#{type}#{rate}#{tags}"
    end
  end

  def send_to_socket(message)
    self.class.logger.debug { "Statsd: #{message}" } if self.class.logger
    @socket.send(message, 0, @host, @port)
  rescue => boom
    self.class.logger.error { "Statsd: #{boom.class} #{boom}" } if self.class.logger
    nil
  end
end
