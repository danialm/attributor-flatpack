# frozen_string_literal: true

module Attributor
  module Flatpack
    class Config < Attributor::Hash
      @separator = '_'
      @key_type = Symbol

      class << self
        def separator(sep = nil)
          return @separator unless sep

          @separator = sep
        end
      end

      def self.inherited(klass)
        super
        sep = self.separator
        klass.instance_eval do
          @separator = sep
        end
        klass.options[:dsl_compiler] = ConfigDSLCompiler
        klass.options[:allow_extra] = true
      end

      def self.from_hash(object, _context, **_opts)
        config = new(object)
        config
      end

      def self.example(context = nil, **values)
        example = super
        # Need the @raw to be set as well, since we're using it in fetch
        contents = example.instance_variable_get(:@contents)
        example.instance_variable_set(:@raw, contents.dup)
        example
      end

      def self.validate_data(data)
        return true unless data.respond_to?(:keys)

        data.keys.each do |k|
          /(.)*/.match?(k)
        rescue TypeError => e
          raise ArgumentError, 'keys must be symboles or strings'
        end
      end

      def initialize(data = nil)
        self.class.validate_data data

        @raw = data
        @contents = {}

        self.class.keys.each do |k, _v|
          self.define_accessors(k)
        end
      end

      def define_accessors(name)
        define_reader(name)
        define_writer(name)
      end

      def define_reader(name)
        context = default_context(name)
        define_singleton_method(name) do
          get(name, context: context)
        end

        attribute = self.class.keys[name]
        return unless attribute.type == Attributor::Boolean

        define_singleton_method(name.to_s + '?') do
          !!get(name, attribute: attribute, context: context)
        end
      end

      def define_writer(name)
        context = ['assignment', "of(#{name})"].freeze
        define_singleton_method(name.to_s + '=') do |value|
          set(name, value, context: context)
        end
      end

      def default_context(key)
        generate_subcontext(Attributor::DEFAULT_ROOT_CONTEXT, key)
      end

      def get(key, context: default_context(key), attribute: self.class.keys[key])
        raise UndefinedKey.new(key, context) unless attribute

        @contents[key] ||= _get(key, attribute: attribute, context: context)
      end

      def _get(key, attribute:, context:)
        if attribute.type < Attributor::Flatpack::Config
          top = fetch(key) do
            {}
          end
          attribute.load(top, context).merge!(subselect(key))
        else
          value = fetch(key) do
            # raise "couldn't find #{key.inspect} anywhere"
            nil
          end
          attribute.load(value, context)
        end
      end

      def set(key, value, context: default_context(key))
        attribute = self.class.keys.fetch key do
          raise UndefinedKey.new(key, [key])
        end

        loaded = attribute.load(value, context)
        @contents[key] = loaded
        @raw[key] = loaded
      end

      # search @raw for key
      def fetch(key)
        return @raw[key] if @raw.key?(key)

        found_key, found_value = @raw.find do |(k, _v)|
          k.to_s.casecmp(key.to_s).zero?
        end

        return found_value if found_key

        yield if block_given?
      end

      def subselect(prefix)
        prefix_match = /^#{prefix}#{::Regexp.escape(self.class.separator)}(.*)/i

        selected = @raw.collect do |(k, v)|
          if (match = prefix_match.match(k))
            [match[1], v]
          end
        end.compact
        ::Hash[selected]
      end

      def [](key)
        get key
      end

      def []=(key, val)
        set key, val
      end

      def merge!(other)
        # Not sure if we need to nuke the memozied set of loaded stuff here
        # or not... but it sounds like a good idea.
        @contents = {}
        @raw.merge!(other)

        self
      end

      # shamelessly copied from Attributor::Model's #validate :(
      def validate(context = Attributor::DEFAULT_ROOT_CONTEXT)
        self.validate_attributes(context) +
          self.validate_requirements(context) +
          self.validate_keys(context)
      end

      def validate_attributes(context)
        self.class.attributes.each_with_object([]) do |(name, attr), errors|
          sub_context = self.generate_subcontext(context, name)
          value = self.get(name)
          errors.push(*attr.validate(value, sub_context))
        end
      end

      def validate_requirements(context)
        self.class.requirements.each_with_object([]) do |req, errors|
          errors.push(req.validate(@contents, context))
        end
      end

      def validate_keys(context)
        return [] if self.class.options[:allow_extra]
        
        errors = (@raw.keys.collect(&:to_s) - self.class.keys.keys.collect(&:to_s)).collect do |extra_key|
          "Unknown key received: #{extra_key.inspect} for #{Attributor.humanize_context(context)}"
        end

        errors
      end

      def pretty_print(context: [])
        self.collect do |k, v|
          sub_context = context + [k]
          case v
          when Attributor::Flatpack::Config
            v.pretty_print(context: context | [k])
          else
            "#{sub_context.join('.')}=#{v.inspect}"
          end
        end.flatten
      end

      def dump(**opts)
        # quick hack to ensure we load all the values into @contents
        self.validate
        super
      end
    end
  end
end
