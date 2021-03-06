require 'prometheus/client'
require 'prometheus/client/formats/text'
require 'fluent/plugin/filter_record_transformer'

module Fluent
  module Plugin
    module PrometheusLabelParser
      def configure(conf)
        super
        # Check if running with multiple workers
        sysconf = if self.respond_to?(:owner) && owner.respond_to?(:system_config)
          owner.system_config
        elsif self.respond_to?(:system_config)
          self.system_config
        else
          nil
        end
        @multi_worker = sysconf && sysconf.workers ? (sysconf.workers > 1) : false
      end

      def parse_labels_elements(conf)
        base_labels = Fluent::Plugin::Prometheus.parse_labels_elements(conf)

        if @multi_worker
          base_labels[:worker_id] = fluentd_worker_id.to_s
        end

        base_labels
      end
    end

    module Prometheus
      class AlreadyRegisteredError < StandardError; end

      def self.parse_labels_elements(conf)
        labels = conf.elements.select { |e| e.name == 'labels' }
        if labels.size > 1
          raise ConfigError, "labels section must have at most 1"
        end

        base_labels = {}
        unless labels.empty?
          labels.first.each do |key, value|
            labels.first.has_key?(key)

            # use RecordAccessor only for $. and $[ syntax
            # otherwise use the value as is or expand the value by RecordTransformer for ${} syntax
            if value.start_with?('$.') || value.start_with?('$[')
              base_labels[key.to_sym] = PluginHelper::RecordAccessor::Accessor.new(value)
            else
              base_labels[key.to_sym] = value
            end
          end
        end

        base_labels
      end

      def self.parse_metrics_elements(conf, registry, labels = {})
        metrics = []
        conf.elements.select { |element|
          element.name == 'metric'
        }.each { |element|
          if element.has_key?('key') && (element['key'].start_with?('$.') || element['key'].start_with?('$['))
            value = element['key']
            element['key'] = PluginHelper::RecordAccessor::Accessor.new(value)
          end
          case element['type']
          when 'summary'
            metrics << Fluent::Plugin::Prometheus::Summary.new(element, registry, labels)
          when 'gauge'
            metrics << Fluent::Plugin::Prometheus::Gauge.new(element, registry, labels)
          when 'counter'
            metrics << Fluent::Plugin::Prometheus::Counter.new(element, registry, labels)
          when 'histogram'
            metrics << Fluent::Plugin::Prometheus::Histogram.new(element, registry, labels)
          else
            raise ConfigError, "type option must be 'counter', 'gauge', 'summary' or 'histogram'"
          end
        }
        metrics
      end

      def self.placeholder_expander(log)
        # Use internal class in order to expand placeholder
        Fluent::Plugin::RecordTransformerFilter::PlaceholderExpander.new(log: log)
      end

      def configure(conf)
        super
        @placeholder_values = {}
        @placeholder_expander = Fluent::Plugin::Prometheus.placeholder_expander(log)
        @hostname = Socket.gethostname
      end

      def instrument_single(tag, time, record, metrics)
        @placeholder_values[tag] ||= {
          'tag' => tag,
          'hostname' => @hostname,
          'worker_id' => fluentd_worker_id,
        }

        placeholders = record.merge(@placeholder_values[tag])
        placeholders = @placeholder_expander.prepare_placeholders(placeholders)
        metrics.each do |metric|
          begin
            metric.instrument(record, @placeholder_expander, placeholders)
          rescue => e
            log.warn "prometheus: failed to instrument a metric.", error_class: e.class, error: e, tag: tag, name: metric.name
            router.emit_error_event(tag, time, record, e)
          end
        end
      end

      def instrument(tag, es, metrics)
        placeholder_values = {
          'tag' => tag,
          'hostname' => @hostname,
          'worker_id' => fluentd_worker_id,
        }

        es.each do |time, record|
          placeholders = record.merge(placeholder_values)
          placeholders = @placeholder_expander.prepare_placeholders(placeholders)
          metrics.each do |metric|
            begin
              metric.instrument(record, @placeholder_expander, placeholders)
            rescue => e
              log.warn "prometheus: failed to instrument a metric.", error_class: e.class, error: e, tag: tag, name: metric.name
              router.emit_error_event(tag, time, record, e)
            end
          end
        end
      end

      class Metric
        attr_reader :type
        attr_reader :name
        attr_reader :key
        attr_reader :desc

        def initialize(element, registry, labels)
          ['name', 'desc'].each do |key|
            if element[key].nil?
              raise ConfigError, "metric requires '#{key}' option"
            end
          end
          @type = element['type']
          @name = element['name']
          @key = element['key']
          @desc = element['desc']

          @base_labels = Fluent::Plugin::Prometheus.parse_labels_elements(element)
          @base_labels = labels.merge(@base_labels)
        end

        def labels(record, expander, placeholders)
          label = {}
          @base_labels.each do |k, v|
            if v.is_a?(String)
              label[k] = expander.expand(v, placeholders)
            else
              label[k] = v.call(record)
            end
          end
          label
        end

        def self.get(registry, name, type, docstring)
          metric = registry.get(name)

          # should have same type, docstring
          if metric.type != type
            raise AlreadyRegisteredError, "#{name} has already been registered as #{type} type"
          end
          if metric.docstring != docstring
            raise AlreadyRegisteredError, "#{name} has already been registered with different docstring"
          end

          metric
        end
      end

      class Gauge < Metric
        def initialize(element, registry, labels)
          super
          if @key.nil?
            raise ConfigError, "gauge metric requires 'key' option"
          end

          begin
            @gauge = registry.gauge(element['name'].to_sym, element['desc'])
          rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
            @gauge = Fluent::Plugin::Prometheus::Metric.get(registry, element['name'].to_sym, :gauge, element['desc'])
          end
        end

        def instrument(record, expander, placeholders)
          if @key.is_a?(String)
            value = record[@key]
          else
            value = @key.call(record)
          end
          if value
            @gauge.set(labels(record, expander, placeholders), value)
          end
        end
      end

      class Counter < Metric
        def initialize(element, registry, labels)
          super
          begin
            @counter = registry.counter(element['name'].to_sym, element['desc'])
          rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
            @counter = Fluent::Plugin::Prometheus::Metric.get(registry, element['name'].to_sym, :counter, element['desc'])
          end
        end

        def instrument(record, expander, placeholders)
          # use record value of the key if key is specified, otherwise just increment
          if @key.nil?
            value = 1
          elsif @key.is_a?(String)
            value = record[@key]
          else
            value = @key.call(record)
          end

          # ignore if record value is nil
          return if value.nil?

          @counter.increment(labels(record, expander, placeholders), value)
        end
      end

      class Summary < Metric
        def initialize(element, registry, labels)
          super
          if @key.nil?
            raise ConfigError, "summary metric requires 'key' option"
          end

          begin
            @summary = registry.summary(element['name'].to_sym, element['desc'])
          rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
            @summary = Fluent::Plugin::Prometheus::Metric.get(registry, element['name'].to_sym, :summary, element['desc'])
          end
        end

        def instrument(record, expander, placeholders)
          if @key.is_a?(String)
            value = record[@key]
          else
            value = @key.call(record)
          end
          if value
            @summary.observe(labels(record, expander, placeholders), value)
          end
        end
      end

      class Histogram < Metric
        def initialize(element, registry, labels)
          super
          if @key.nil?
            raise ConfigError, "histogram metric requires 'key' option"
          end

          begin
            if element['buckets']
              buckets = element['buckets'].split(/,/).map(&:strip).map do |e|
                e[/\A\d+.\d+\Z/] ? e.to_f : e.to_i
              end
              @histogram = registry.histogram(element['name'].to_sym, element['desc'], {}, buckets)
            else
              @histogram = registry.histogram(element['name'].to_sym, element['desc'])
            end
          rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
            @histogram = Fluent::Plugin::Prometheus::Metric.get(registry, element['name'].to_sym, :histogram, element['desc'])
          end
        end

        def instrument(record, expander, placeholders)
          if @key.is_a?(String)
            value = record[@key]
          else
            value = @key.call(record)
          end
          if value
            @histogram.observe(labels(record, expander, placeholders), value)
          end
        end
      end
    end
  end
end
