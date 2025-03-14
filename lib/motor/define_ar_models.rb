# frozen_string_literal: true

module Motor
  module DefineArModels
    EXCLUDE_TABLES = Set.new(
      %w[
        active_storage_blobs
        active_storage_variant_records
        motor_admin_user_roles
        motor_admin_users
        motor_alert_locks
        motor_alerts
        motor_dashboards
        motor_encrypted_configs
        motor_forms
        motor_resources
        motor_roles
        motor_taggable_tags
        motor_tags
        active_storage_attachments
        ar_internal_metadata
        motor_audits
        motor_configs
        motor_queries
        schema_migrations
      ]
    ).freeze

    DEFINED_MODELS = HashWithIndifferentAccess.new
    TABLE_INDEXES_CACHE = HashWithIndifferentAccess.new
    ENUM_TYPE_VALUES_CACHE = HashWithIndifferentAccess.new
    TIMESTAMP_COLUMNS = %w[updated_at created_at].freeze

    MUTEX = Mutex.new

    mattr_accessor :defined_models_connection_url

    module_function

    def call
      tables = ResourceRecord.connection.tables

      MUTEX.synchronize do
        clear_models if current_connection_url != defined_models_connection_url

        define_models(tables).each do |model|
          next unless model.table_exists?

          assign_primary_key(model)
          define_model_validators(model)
          define_model_reflections(model)
          define_model_many_to_many(model) if join_table_model?(model)
        end

        self.defined_models_connection_url = current_connection_url
      end
    end

    def clear_models
      DEFINED_MODELS.each_value { |klass| Object.send(:remove_const, klass.name) }

      DEFINED_MODELS.clear
    end

    def current_connection_url
      ::ResourceRecord.connection_db_config.try(:url)
    end

    def define_models(tables)
      tables.filter_map do |name|
        next if EXCLUDE_TABLES.include?(name)

        class_name = name.classify

        klass = begin
          Object.const_get(class_name)
        rescue NameError
          nil
        end

        next if klass && ActiveRecord::Base.descendants.include?(klass)

        model = Class.new(ResourceRecord)

        DEFINED_MODELS[name] = model

        Object.const_set(class_name, model)
      end
    end

    def assign_primary_key(model)
      return if model.primary_key

      indexes = fetch_table_indexes(model)

      primary_key_column =
        model.columns.reject(&:null).find do |column|
          indexes.find { |index| index.unique && index.columns == [column.name] }
        end

      return unless primary_key_column

      model.primary_key = primary_key_column.name
    end

    def define_model_validators(model)
      define_presence_validators(model)
      define_enum_validators(model)
    end

    def define_enum_validators(model)
      return if model.connection.class.to_s != 'ActiveRecord::ConnectionAdapters::PostgreSQLAdapter'

      model.columns.each do |column|
        next if column.type != :enum

        ENUM_TYPE_VALUES_CACHE[column.sql_type] ||=
          model.pluck(Arel.sql("unnest(enum_range(NULL::#{column.sql_type}))::text")).uniq

        model.validates_inclusion_of column.name, in: ENUM_TYPE_VALUES_CACHE[column.sql_type]
      end
    end

    def define_presence_validators(model)
      required_columns =
        model.columns.reject do |column|
          column.name == model.primary_key ||
            column.null ||
            column.default ||
            column.default_function ||
            column.type == :boolean ||
            column.name.in?(TIMESTAMP_COLUMNS)
        end

      return if required_columns.blank?

      model.validates_presence_of(required_columns.map(&:name))
    end

    # rubocop:disable Metrics/AbcSize
    def define_model_many_to_many(model)
      ref_one, ref_two = model.reflections.values

      ref_one_name = (ref_two.inverse_of.has_one? ? ref_one.name : ref_one.klass.table_name).to_sym
      ref_two_name = (ref_one.inverse_of.has_one? ? ref_two.name : ref_two.klass.table_name).to_sym

      ref_one.klass.public_send(ref_one.inverse_of.has_one? ? :has_one : :has_many,
                                ref_two_name, through: ref_one.inverse_of.name, inverse_of: ref_one_name)

      ref_two.klass.public_send(ref_two.inverse_of.has_one? ? :has_one : :has_many,
                                ref_one_name, through: ref_two.inverse_of.name, inverse_of: ref_two_name)
    end
    # rubocop:enable Metrics/AbcSize

    def join_table_model?(model)
      join_columns = model.columns.reject do |column|
        column.name == 'id' || column.name.in?(TIMESTAMP_COLUMNS)
      end

      return unless join_columns.size.in?([2, 3])
      return if model.reflections.size != 2

      belongs_to_reflections = model.reflections.values.select(&:belongs_to?)

      return if belongs_to_reflections.size != 2

      true
    end

    def fetch_table_indexes(model)
      TABLE_INDEXES_CACHE[model.table_name] ||= ResourceRecord.connection.indexes(model.table_name)
    end

    def define_model_reflections(model)
      model.columns.each do |column|
        next unless column.name.ends_with?('_id')
        next if column.try(:array?)

        belongs_to_name = column.name.delete_suffix('_id')

        next if model.columns_hash["#{belongs_to_name}_type"]

        ref_model = DEFINED_MODELS[belongs_to_name.pluralize]

        next unless ref_model

        define_model_reflection(model, ref_model, column, belongs_to_name.to_sym)
      end
    end

    def define_model_reflection(model, ref_model, column, belongs_to_name)
      is_has_one = fetch_table_indexes(model).any? { |index| index.unique && index.columns == [column.name] }
      inverse_of_name = (is_has_one ? model.name.underscore : model.table_name).to_sym

      model.belongs_to(belongs_to_name, optional: column.null, inverse_of: inverse_of_name)

      if is_has_one
        ref_model.has_one(inverse_of_name, dependent: :destroy, inverse_of: belongs_to_name)
      else
        ref_model.has_many(inverse_of_name, dependent: :destroy, inverse_of: belongs_to_name)
      end
    end
  end
end
