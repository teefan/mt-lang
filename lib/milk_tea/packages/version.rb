# frozen_string_literal: true

module MilkTea
  class PackageVersionError < StandardError; end

  class PackageVersion
    include Comparable

    VERSION_PATTERN = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/

    attr_reader :major, :minor, :patch

    def self.parse(value, label: "package version")
      return value if value.is_a?(self)

      text = value.to_s.strip
      raise PackageVersionError, "#{label} cannot be empty" if text.empty?

      match = VERSION_PATTERN.match(text)
      unless match
        raise PackageVersionError,
              "#{label} #{text.inspect} must use semantic version format MAJOR.MINOR.PATCH"
      end

      new(match[1].to_i, match[2].to_i, match[3].to_i)
    end

    def initialize(major, minor, patch)
      @major = Integer(major)
      @minor = Integer(minor)
      @patch = Integer(patch)
    end

    def <=>(other)
      return nil unless other.is_a?(PackageVersion)

      [major, minor, patch] <=> [other.major, other.minor, other.patch]
    end

    def to_s
      "#{major}.#{minor}.#{patch}"
    end
  end

  class PackageVersionReq
    Constraint = Data.define(:operator, :version) do
      def matches?(candidate)
        case operator
        when :eq
          candidate == version
        when :gt
          candidate > version
        when :gte
          candidate >= version
        when :lt
          candidate < version
        when :lte
          candidate <= version
        else
          raise PackageVersionError, "unsupported package version operator #{operator.inspect}"
        end
      end

      def to_s
        prefix = case operator
                 when :eq then "="
                 when :gt then ">"
                 when :gte then ">="
                 when :lt then "<"
                 when :lte then "<="
                 else
                   raise PackageVersionError, "unsupported package version operator #{operator.inspect}"
                 end

        "#{prefix}#{version}"
      end
    end

    attr_reader :constraints

    def self.parse(value, label: "package version requirement")
      text = value.to_s.strip
      raise PackageVersionError, "#{label} cannot be empty" if text.empty?

      segments = text.split(",", -1).map(&:strip)
      if segments.empty? || segments.any?(&:empty?)
        raise PackageVersionError, "#{label} #{text.inspect} contains an empty constraint"
      end

      constraints = segments.flat_map do |segment|
        parse_segment(segment, label:)
      end

      new(constraints)
    end

    def self.parse_segment(segment, label:)
      case segment
      when /\A\^(.+)\z/
        version = PackageVersion.parse(Regexp.last_match(1), label:)
        [Constraint.new(:gte, version), Constraint.new(:lt, caret_upper_bound(version))]
      when /\A~(.+)\z/
        version = PackageVersion.parse(Regexp.last_match(1), label:)
        [Constraint.new(:gte, version), Constraint.new(:lt, tilde_upper_bound(version))]
      when /\A(>=|<=|>|<|=)\s*(.+)\z/
        version = PackageVersion.parse(Regexp.last_match(2), label:)
        [Constraint.new(operator_for(Regexp.last_match(1)), version)]
      else
        [Constraint.new(:eq, PackageVersion.parse(segment, label:))]
      end
    end
    private_class_method :parse_segment

    def self.operator_for(token)
      case token
      when "=" then :eq
      when ">" then :gt
      when ">=" then :gte
      when "<" then :lt
      when "<=" then :lte
      else
        raise PackageVersionError, "unsupported package version operator #{token.inspect}"
      end
    end
    private_class_method :operator_for

    def self.caret_upper_bound(version)
      if version.major.positive?
        PackageVersion.new(version.major + 1, 0, 0)
      elsif version.minor.positive?
        PackageVersion.new(0, version.minor + 1, 0)
      else
        PackageVersion.new(0, 0, version.patch + 1)
      end
    end
    private_class_method :caret_upper_bound

    def self.tilde_upper_bound(version)
      PackageVersion.new(version.major, version.minor + 1, 0)
    end
    private_class_method :tilde_upper_bound

    def initialize(constraints)
      @constraints = constraints.freeze
    end

    def exact?
      constraints.length == 1 && constraints.first.operator == :eq
    end

    def exact_version
      constraints.first.version if exact?
    end

    def matches?(version)
      candidate = PackageVersion.parse(version)
      constraints.all? { |constraint| constraint.matches?(candidate) }
    end

    def to_s
      constraints.map(&:to_s).join(", ")
    end
  end
end
