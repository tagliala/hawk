module Hawk
  module Model

    module Association
      # Initialize the associations registry
      #
      def self.included(base)
        base.extend ClassMethods
        base.instance_eval { @_associations ||= {} }
      end

      # Load associations early, to memoize them and avoid having
      # Hashes when a Model is more appropriate.
      #
      def initialize(attributes = {})
        if attributes.size > 0 && self.class.associations?
          preload_associations(attributes, self.class)
        end

        super
      end

      private
        def preload_associations(attributes, scope)
          scope.associations.each do |name, (_, options)|
            if (repr = scope.preload_association.call(attributes, name, options))
              target = options.fetch(:class_name)

              # This is a bit naive. But it's convention over configuration. And makes you architect
              # stuff The Right Way, not throwing randomly stuff around hoping it'll magically work.
              target = scope.const_defined?(target) ? scope.const_get(target) : scope.parent.const_get(target)

              instance_variable_set("@_#{name}", target.instantiate_from(repr))
            end
          end
        end

      module ClassMethods
        # Propagate associations to the subclasses on inheritance
        #
        def inherited(subclass)
          super

          parent = self
          subclass.instance_eval do
            @_associations ||= {}

            parent.associations.each do |name, (type, options)|
              _define_association(name, type, options)
            end
          end
        end

        # Defines how associations should be preloaded.
        #
        # The given block gets called when a new entity is instantiated, and
        # it gets passed the object attributes, the association's name, type
        # and options.
        #
        # Example (for Joe :-)
        #
        #     class Foo < Hawk::Model::Base
        #
        #       has_many :bars
        #
        #       preload_associations do |attributes, name, type, options|
        #         if attributes.key?('links')
        #           links = attributes['links']
        #           if links.key?(name)
        #             return attributes.delete(links[name])
        #           end
        #         end
        #       end
        #
        #     end
        #
        # The block would get called once, with :bars as `name`, :has_many as
        # `type` and `{class_name: 'Bar', primary_key: 'foo_id'} as `options`
        #
        # By default it looks up in the representation a property named after
        # the association's name, and returns it, deleting it from the repr.
        #
        def preload_association(&block)
          @_preload_association = block if block
          @_preload_association ||= lambda do |attributes, name, options|
            attr = name.to_s

            if attributes.key?(attr)
              return attributes.delete(attr)
            end
          end
        end

        # Return a copy of the associations registry
        #
        def associations
          @_associations.dup
        end

        # Check whether associations are defined
        #
        def associations?
          @_associations && @_associations.size > 0
        end

        # Adds an has_many association, mimicking ActiveRecord's interface
        # TODO better documentation
        #
        def has_many(entities, options = {})
          entity = entities.to_s.singularize
          klass  = options[:class_name] || entity.camelize
          key    = options[:primary_key] || [self.name.demodulize.underscore, :id].join('_')
          from   = options[:from]
          # TODO params

          if from && from[0,4] != 'http'
            from = ['/', from].join unless from[0] == '/'
            from = [site, from].join
          end

          _define_association(entities, :has_many, class_name: klass, primary_key: key, from: from)
        end

        # Adds an has_one association, mimicking ActiveRecord's interface
        # TODO better documentation
        #
        def has_one(entity, options = {})
          entity = entity.to_s.singularize
          klass  = options[:class_name] || entity.camelize
          # TODO params

          _define_association(entity, :has_one, class_name: klass)
        end

        # Adds a belongs_to association, mimicking ActiveRecord's interface
        # TODO better documentation
        #
        def belongs_to(entity, options = {})
          if options[:polymorphic]
            polymorphic_belongs_to(entity, options)
          else
            monomorphic_belongs_to(entity, options)
          end
        end

        protected

        def monomorphic_belongs_to(entity, options)
          klass  = options[:class_name] || entity.to_s.camelize
          key    = options[:primary_key] || [entity, :id].join('_')
          params = options.fetch(:params, {})

          _define_association(entity, :monomorphic_belongs_to, class_name: klass, primary_key: key, params: params)
        end

        def polymorphic_belongs_to(entity, options)
          key = [options[:as] || entity, :id].join('_')
          # TODO params

          _define_association(entity, :polymorphic_belongs_to, as: key)
        end

        private

        def _define_association(name, type, options)
          @_associations[name] = [type, options]
          instance_exec(name, options, &CODE.fetch(type))
        end

        # The raw associations code
        #
        CODE = {
          has_many: -> (entities, options) {
            klass, key, from = options.values_at(*[:class_name, :primary_key, :from])

            class_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{entities}
                @_#{entities} ||= #{parent}::#{klass}.where(#{key}: self.id, from: #{from.inspect})
              end
            RUBY
          },

          has_one: -> (entity, options) {
            klass = options[:class_name]

            class_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{entity}!
                @_#{entity} ||= #{parent}::#{klass}.new(get(:#{entity}), true)
              end

              def #{entity}
                #{entity}!
              rescue Hawk::Error::NotFound
                nil
              end
            RUBY
          },

          monomorphic_belongs_to: -> (entity, options) {
            klass, key, params = options.values_at(*[:class_name, :primary_key, :params])
            ivar = "@_#{entity}".intern

            class_eval do
              define_method(entity) do
                return unless (id = self.attributes.fetch(key.to_s, nil))
                params = instance_eval(&params) if params.respond_to?(:call)

                instance_variable_get(ivar) || begin
                  instance = self.class.parent.const_get(klass).find(id, params || {})
                  instance_variable_set(ivar, instance)
                end
              end
            end
          },

          polymorphic_belongs_to: -> (entity, options) {
            key = options.fetch(:as)

            class_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{entity}
                @_#{entity} ||= begin
                  return unless self.#{key}
                  klass = self.class.parent.const_get(self.#{entity}_type)
                  klass.find(self.#{key})
                end
              end
            RUBY
          }

        }.freeze
      end
    end

  end
end
