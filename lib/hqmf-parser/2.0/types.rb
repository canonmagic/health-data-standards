module HQMF2
  # Used to represent 'any value' in criteria that require a value be present but
  # don't specify any restrictions on that value
  class AnyValue
    attr_reader :type

    def initialize(type='ANYNonNull')
      @type = type
    end

    def to_model
      HQMF::AnyValue.new(@type)
    end
  end

  # Represents a bound within a HQMF pauseQuantity, has a value, a unit and an
  # inclusive/exclusive indicator
  class Value
    include HQMF2::Utilities

    attr_reader :type, :unit, :value

    def initialize(entry, default_type='PQ', force_inclusive=false)
      @entry = entry
      @type = attr_val('./@xsi:type') || default_type
      @unit = attr_val('./@unit')
      @value = attr_val('./@value')
      @force_inclusive = force_inclusive

      # FIXME: Remove below when lengthOfStayQuantity unit is fixed
      @unit = 'd' if @unit=='days'
    end

    def inclusive?
      v = attr_val("../@#{@entry.name}Closed")
      v == nil || v != 'false' || @force_inclusive
    end

    def derived?
      case attr_val('./@nullFlavor')
      when 'DER'
        true
      else
        false
      end
    end

    def expression
      if !derived?
        nil
      else
        attr_val('./cda:expression/@value')
      end
    end

    def to_model
      HQMF::Value.new(type,unit,value,inclusive?,derived?,expression)
    end
  end

  # Represents a HQMF physical quantity which can have low and high bounds
  class Range
    include HQMF2::Utilities
    attr_accessor :low, :high, :width

    def initialize(entry, type=nil)
      @type = type
      @entry = entry
      if @entry
        @low = optional_value("#{default_element_name}/cda:low", default_bounds_type)
        @low = nil unless (@low.try(:value) || @low.kind_of?( HQMF2::AnyValue))
        @high = optional_value("#{default_element_name}/cda:high", default_bounds_type)
        @high = nil unless (@high.try(:value) || @high.kind_of?(HQMF2::AnyValue))
        # Unset low bound to resolve verbose value bounds descriptions
        @low = nil if @high.try(:value) && @high.value.try(:to_i) > 0 && @low.try(:value) && @low.value.try(:to_i) == 0
        @width = optional_value("#{default_element_name}/cda:width", 'PQ')
        detect_period
      end
    end

    def type
      @type || attr_val('./@xsi:type')
    end

    def to_model
      lm = low ? low.to_model : nil
      hm = high ? high.to_model : nil
      wm = width ? width.to_model : nil
      model_type = type
      if @entry.at_xpath('./cda:uncertainRange', HQMF2::Document::NAMESPACES)
        model_type = 'IVL_PQ'
      end
      HQMF::Range.new(model_type, lm, hm, wm)
    end

    private

    def optional_value(xpath, type)
      value_def = @entry.at_xpath(xpath, HQMF2::Document::NAMESPACES)
      if value_def # && (!value_def["value"].blank? && value_def["value"].to_i > 0)
        if value_def["flavorId"] == "ANY.NONNULL"
          AnyValue.new
        else
          Value.new(value_def, type)
        end
      else
        nil
      end
    end

    def default_element_name
      case type
      when 'IVL_PQ'
        '.'
      when 'IVL_TS'
        'cda:phase'
      else
        'cda:uncertainRange'
      end
    end

    def default_bounds_type
      case type
      when 'IVL_TS'
        'TS'
      else
        'PQ'
      end
    end

    # TODO: Update this to actually compute the correct end time for the period
    def detect_period
      if @low && @high.nil?
        period = optional_value("cda:period", default_bounds_type)
        if period.try(:unit) == 'a' && period.try(:value) == '1'
          high_entry = @entry.at_xpath("#{default_element_name}/cda:low", HQMF2::Document::NAMESPACES).dup
          high_entry.attributes["value"].value = '20151231' if @low.value == '20150101'
          @high = Value.new(high_entry, default_bounds_type, attr_val("cda:phase/@highClosed") == 'true')
          @high = nil unless @high.try(:value)
        end
      end
    end
  end

  # Represents a HQMF effective time which is a specialization of a interval
  class EffectiveTime < Range
    def initialize(entry)
      super
    end

    def type
      'IVL_TS'
    end
  end

  # Represents a HQMF CD value which has a code and codeSystem
  class Coded
    include HQMF2::Utilities

    def initialize(entry)
      @entry = entry
    end

    def type
      attr_val('./@xsi:type') || 'CD'
    end

    def system
      attr_val('./@codeSystem')
    end

    def code
      attr_val('./@code')
    end

    def code_list_id
      attr_val('./@valueSet')
    end

    def title
      attr_val('./*/@value')
    end

    def value
      code
    end

    def derived?
      false
    end

    def unit
      nil
    end

    def to_model
      HQMF::Coded.new(type, system, code, code_list_id, title)
    end

  end

  class SubsetOperator
    include HQMF2::Utilities

    attr_reader :type, :value
    ORDER_SUBSETS = ['FIRST','SECOND','THIRD','FOURTH','FIFTH']
    LAST_SUBSETS = ['LAST', 'RECENT']
    TIME_SUBSETS = ['DATEDIFF', 'TIMEDIFF']
    QDM_TYPE_MAP = {'QDM_LAST:'=>'RECENT', 'QDM_SUM:SUM' => 'COUNT'}

    def initialize(entry)
      @entry = entry

      sequence_number = attr_val('./cda:sequenceNumber/@value')
      qdm_subset_code = attr_val('./qdm:subsetCode/@code')
      subset_code = attr_val('./cda:subsetCode/@code')
      if (sequence_number)
        @type = ORDER_SUBSETS[sequence_number.to_i-1]
      else
        @type = translate_type(subset_code, qdm_subset_code)
      end

      value_def = @entry.at_xpath('./*/cda:repeatNumber', HQMF2::Document::NAMESPACES)
      if !value_def
        value_def = @entry.at_xpath('./*/cda:value', HQMF2::Document::NAMESPACES)
      end
      if value_def
        value_type = value_def.at_xpath('./@xsi:type', HQMF2::Document::NAMESPACES)
        if String.try_convert(value_type) ==  "ANY"
          @value = HQMF2::AnyValue.new()
        end
      end

      if value_def && !@value
        @value = HQMF2::Range.new(value_def, 'IVL_PQ')
      end
    end

    def translate_type(subset_code, qdm_subset_code)
      combined = "#{qdm_subset_code}:#{subset_code}"
      if (QDM_TYPE_MAP[combined])
        QDM_TYPE_MAP[combined]
      else
        subset_code
      end

    end

    def to_model
      vm = value ? value.to_model : nil
      HQMF::SubsetOperator.new(type, vm)
    end
  end

  class TemporalReference
    include HQMF2::Utilities

    attr_reader :type, :reference, :range

    def initialize(entry)
      @entry = entry
      @type = attr_val('./@typeCode')
      @reference = Reference.new(@entry.at_xpath('./*/cda:id', HQMF2::Document::NAMESPACES))
      range_def = @entry.at_xpath('./qdm:temporalInformation/qdm:delta', HQMF2::Document::NAMESPACES)
      if range_def
        @range = HQMF2::Range.new(range_def, 'IVL_PQ')
      end
    end

    def to_model
      rm = range ? range.to_model : nil
      HQMF::TemporalReference.new(type, reference.to_model, rm)
    end
  end

# Represents a HQMF reference to a data criteria that has a given type
  class TypedReference
    include HQMF2::Utilities
    attr_accessor :id, :type, :mood

    # Create a new HQMF::Reference
    # @param [String] id
    def initialize(entry)
      @entry = entry
      @type = type || attr_val('./@classCode')
      @mood = attr_val('./@moodCode')
      @entry = entry.elements.first unless entry.at_xpath('./@extension')
    end

    def reference
      id = strip_tokens attr_val('./@extension')
      if id =~ /^[0-9]/ then "prefix_#{id}" else id end
    end

    def to_model
      HQMF::TypedReference.new(reference,@type,@mood)
    end

  end

  # Represents a HQMF reference from a precondition to a data criteria
  class Reference
    include HQMF2::Utilities

    def initialize(entry)
      @entry = entry
    end

    def id
      if @entry.kind_of? String
        @entry
      else
        id = strip_tokens attr_val('./@extension')
        # Handle MeasurePeriod references for calculation code
        id = 'MeasurePeriod' if id == 'measureperiod'
        if id =~ /^[0-9]/ then "prefix_#{id}" else id end
      end
    end

    def to_model
      HQMF::Reference.new(id)
    end
  end

  class DataCriteriaWrapper

    attr_accessor  :status, :value, :effective_time
    attr_accessor :temporal_references, :subset_operators, :children_criteria
    attr_accessor :derivation_operator, :negation, :negation_code_list_id, :description
    attr_accessor :field_values, :source_data_criteria, :specific_occurrence_const
    attr_accessor :specific_occurrence, :comments
    attr_accessor :id, :title, :definition, :variable, :code_list_id, :value, :inline_code_list

    def initialize(opts={})
     opts.each { |k,v| instance_variable_set("@#{k}", v) }
    end

    def to_model
      mv = @value ? @value.to_model : nil
      met = @effective_time ? @effective_time.to_model : nil
      mtr = @temporal_references
      mso = @subset_operators
      HQMF::DataCriteria.new(@id, @title, nil, @description, @code_list_id, @children_criteria,
        @derivation_operator, @definition, @status, mv, field_values, met, @inline_code_list,
        @negation, @negation_code_list_id, mtr, mso, @specific_occurrence,
        @specific_occurrence_const, @source_data_criteria, @comments, @variable)
    end
  end
end
