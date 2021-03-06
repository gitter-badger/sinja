# frozen_string_literal: true
require 'active_support/inflector'
require 'json'
require 'jsonapi-serializers'
require 'set'

module Sinja
  module Helpers
    module Serializers
      def dedasherize(s=nil)
        s.to_s.tr('-', '_').send(Symbol === s ? :to_sym : :itself)
      end

      def dedasherize_names(*args)
        _dedasherize_names(*args).to_h
      end

      private def _dedasherize_names(hash={})
        return enum_for(__callee__, hash) unless block_given?

        hash.each do |k, v|
          yield dedasherize(k), Hash === v ? dedasherize_names(v) : v
        end
      end

      def deserialize_request_body
        return {} unless content?

        request.body.rewind
        JSON.parse(request.body.read, :symbolize_names=>true)
      rescue JSON::ParserError
        raise BadRequestError, 'Malformed JSON in the request body'
      end

      def serialize_response_body
        JSON.send settings._sinja.json_generator, response.body
      rescue JSON::GeneratorError
        raise BadRequestError, 'Unserializable entities in the response body'
      end

      def include_exclude!(options)
        included, default, excluded =
          params[:include],
          options.delete(:include) || [],
          options.delete(:exclude) || []

        if included.empty?
          included = Array === default ? default : default.split(',')

          return included if included.empty?
        end

        excluded = Array === excluded ? excluded : excluded.split(',')
        unless excluded.empty?
          excluded = Set.new(excluded)
          included.delete_if do |termstr|
            terms = termstr.split('.')
            terms.length.times.any? do |i|
              excluded.include?(terms.take(i.succ).join('.'))
            end
          end

          return included if included.empty?
        end

        return included unless settings._resource_config

        # Walk the tree and try to exclude based on fetch and pluck permissions
        included.keep_if do |termstr|
          catch :keep? do
            *terms, last_term = termstr.split('.')

            # Start cursor at root of current resource
            config = settings._resource_config
            terms.each do |term|
              # Move cursor through each term, avoiding the default proc,
              # halting if no roles found, i.e. client asked to include
              # something that Sinja doesn't know about
              throw :keep?, true \
                unless config = settings._sinja.resource_config.fetch(term.pluralize.to_sym, nil)
            end

            roles = (
              config.dig(:has_many, last_term.pluralize.to_sym, :fetch) ||
              config.dig(:has_one, last_term.singularize.to_sym, :pluck)
            )[:roles]

            throw :keep?, roles && (roles.empty? || roles === memoized_role)
          end
        end
      end

      def serialize_model(model=nil, options={})
        options[:is_collection] = false
        options[:skip_collection_check] = defined?(::Sequel) && ::Sequel::Model === model
        options[:include] = include_exclude!(options)
        options[:fields] ||= params[:fields] unless params[:fields].empty?
        options = settings._sinja.serializer_opts.merge(options)

        ::JSONAPI::Serializer.serialize(model, options)
      end

      def serialize_model?(model=nil, options={})
        if model
          body serialize_model(model, options)
        elsif options.key?(:meta)
          body serialize_model(nil, :meta=>options[:meta])
        else
          status 204
        end
      end

      def serialize_models(models=[], options={})
        options[:is_collection] = true
        options[:include] = include_exclude!(options)
        options[:fields] ||= params[:fields] unless params[:fields].empty?
        options = settings._sinja.serializer_opts.merge(options)

        if options.key?(:links) && pagination = options[:links].delete(:pagination)
          options[:links][:self] = request.url unless pagination.key?(:self)

          query = Rack::Utils.build_nested_query \
            env['rack.request.query_hash'].dup.tap { |h| h.delete('page') }
          self_link, join_char =
            if query.empty?
              [request.path, ??]
            else
              ["#{request.path}?#{query}", ?&]
            end

          %i[self first prev next last].each do |key|
            next unless pagination.key?(key)
            query = Rack::Utils.build_nested_query \
              :page=>pagination[key]
            options[:links][key] = "#{self_link}#{join_char}#{query}"
          end
        end

        ::JSONAPI::Serializer.serialize([*models], options)
      end

      def serialize_models?(models=[], options={})
        if [*models].any?
          body serialize_models(models, options)
        elsif options.key?(:meta)
          body serialize_models([], :meta=>options[:meta])
        else
          status 204
        end
      end

      def serialize_linkage(model, rel, options={})
        options[:is_collection] = false
        options[:skip_collection_check] = defined?(::Sequel) && ::Sequel::Model === model
        options[:include] = rel.to_s
        options = settings._sinja.serializer_opts.merge(options)

        # TODO: This is extremely wasteful. Refactor JAS to expose the linkage serializer?
        content = ::JSONAPI::Serializer.serialize(model, options)
        content['data']['relationships'][rel.to_s].tap do |linkage|
          %w[meta jsonapi].each do |key|
            linkage[key] = content[key] if content.key?(key)
          end
        end
      end

      def serialize_linkage?(updated=false, options={})
        body updated ? serialize_linkage(options) : serialize_model?(nil, options)
      end

      def serialize_linkages?(updated=false, options={})
        body updated ? serialize_linkage(options) : serialize_models?([], options)
      end

      def error_hash(title: nil, detail: nil, source: nil)
        [
          { id: SecureRandom.uuid }.tap do |hash|
            hash[:title] = title if title
            hash[:detail] = detail if detail
            hash[:status] = status.to_s if status
            hash[:source] = source if source
          end
        ]
      end

      def exception_title(e)
        if e.respond_to?(:title)
          e.title
        else
          e.class.name.split('::').last.split(/(?=[[:upper:]])/).join(' ')
        end
      end

      def serialize_errors(&block)
        raise env['sinatra.error'] if env['sinatra.error'] && sideloaded?

        error_hashes =
          if [*body].any?
            if [*body].all? { |error| Hash === error }
              # `halt' with a hash or array of hashes
              [*body].flat_map { |error| error_hash(error) }
            elsif not_found?
              # `not_found' or `halt 404'
              message = [*body].first.to_s
              error_hash \
                :title=>'Not Found Error',
                :detail=>(message unless message == '<h1>Not Found</h1>')
            else
              # `halt'
              error_hash \
                :title=>'Unknown Error',
                :detail=>[*body].first.to_s
            end
          end

        # Exception already contains formatted errors
        error_hashes ||= env['sinatra.error'].error_hashes \
          if env['sinatra.error'].respond_to?(:error_hashes)

        error_hashes ||=
          case e = env['sinatra.error']
          when UnprocessibleEntityError
            e.tuples.flat_map do |attribute, full_message|
              error_hash \
                :title=>exception_title(e),
                :detail=>full_message.to_s,
                :source=>{
                  :pointer=>(attribute ? "/data/attributes/#{attribute.to_s.dasherize}" : '/data')
                }
            end
          when Exception
            error_hash \
              :title=>exception_title(e),
              :detail=>(e.message.to_s unless e.message == e.class.name)
          else
            error_hash \
              :title=>'Unknown Error'
          end

        error_hashes.each { |h| instance_exec(h, &block) } if block

        content_type :api_json
        JSON.send settings._sinja.json_error_generator,
          ::JSONAPI::Serializer.serialize_errors(error_hashes)
      end
    end
  end
end
