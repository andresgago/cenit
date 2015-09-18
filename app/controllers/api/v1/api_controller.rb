module Api::V1
  class ApiController < ApplicationController
    before_action :authorize, :do_optimize_data_type_handling, :save_request_data, except: [:new_account]
    before_action :find_item, only: [:show, :destroy, :pull, :run]
    rescue_from Exception, :with => :exception_handler
    respond_to :json

    def index
      if klass = self.klass
        @items =
            if @criteria.present?
              if sort_key = @criteria.delete(:sort_by)
                asc = @criteria.has_key?(:ascending) | @criteria.has_key?(:asc)
                [:ascending, :asc, :descending, :desc].each { |key| @criteria.delete(key) }
              end
              if limit = @criteria.delete(:limit)
                limit = limit.to_s.to_i
                limit = nil if limit == 0
              end
              items = klass.where(@criteria)
              items = items.sort(sort_key => asc ? 1 : -1) if sort_key
              items = items.limit(limit) if limit
              items
            else
              klass.all
            end
        render json: @items.map { |item| {((model = (hash = item.inspect_json(include_id: true)).delete('_type')) ? model.downcase : @model) => hash} }
      else
        render json: {error: 'no model found'}, status: :not_found
      end
    end

    def show
      if @item.orm_model.data_type.is_a?(Setup::FileDataType)
        send_data @item.data, filename: @item[:filename], type: @item[:contentType]
      else
        render json: {@model => @item.to_hash}
      end
    end

    def push
      response =
          {
              success: success_report = Hash.new { |h, k| h[k] = [] },
              errors: broken_report = Hash.new { |h, k| h[k] = [] }
          }
      @payload.each do |root, message|
        if data_type = @payload.data_type_for(root)
          message = [message] unless message.is_a?(Array)
          message.each do |item|
            if (record = data_type.send(@payload.create_method,
                                        @payload.process_item(item, data_type),
                                        options = @payload.create_options)).errors.blank?
              success_report[root.pluralize] << record.inspect_json(inspecting: :id, inspect_scope: options[:create_collector])
            else
              broken_report[root] << {errors: record.errors.full_messages, item: item}
            end
          end
        else
          broken_report[root] = 'no model found'
        end
      end
      response.delete(:success) if success_report.blank?
      response.delete(:errors) if broken_report.blank?
      render json: response
    end

    def destroy
      if Setup::Models.registered?(klass) && Setup::Models.excluded_actions_for(klass).include?(:delete)
        render json: {status: :not_allowed}
      else
        @item.destroy
        render json: {status: :ok}
      end
    end

    def run
      if @item.is_a?(Setup::Algorithm)
        begin
          render plain: @item.run(@webhook_body)
        rescue Exception => ex
          render json: {error: ex.message}, status: 406
        end
      else
        render json: {status: :not_allowed}, status: 405
      end
    end

    def pull
      if @item.is_a?(Setup::SharedCollection)
        begin
          pull_request = Cenit::Actions.pull(@item, @webhook_body.present? ? JSON.parse(@webhook_body) : {})
          pull_request.each { |key, value| pull_request.delete(key) unless value.present? }
          if pull_request[:missing_parameters]
            pull_request.delete(:updated_records)
          elsif updated_records = pull_request[:updated_records]
            updated_records.each do |key, records|
              updated_records[key] = records.collect { |record| {id: record.id.to_s} }
            end
          end
          render json: pull_request
        rescue Exception => ex
          render json: {status: :bad_request}
        end
      else
        render json: {status: :not_allowed}
      end
    end

    def auth
      head :no_content
    end

    def new_account
      data = (JSON.parse(@webhook_body) rescue {}).keep_if { |key, _| %w(email password password_confirmation token code).include?(key) }
      data = data.with_indifferent_access
      data.reverse_merge!(email: params[:email], password: pwd = params[:password], password_confirmation: params[:password_confirmation] || pwd)
      status = 406
      response =
          if token = data[:token] || params[:token]
            if tkaptcha = TkAptcha.where(token: token).first
              if code = data[:code] || params[:code]
                if code == tkaptcha.code
                  data.merge!(tkaptcha.data || {}) { |_, left, right| left || right }
                  data[:password] = Devise.friendly_token unless data[:password]
                  data[:password_confirmation] = data[:password] unless data[:password_confirmation]
                  tkaptcha.destroy
                  user =
                      begin
                        (user = User.new_with_session(data, session)).save
                        user
                      rescue
                        user #TODO Handle sending confirmation email error
                      end
                  if user.errors.blank?
                    Account.create_with_owner(owner: user)
                    status = 200
                    {number: user.number, token: user.authentication_token}
                  else
                    user.errors.to_json
                  end
                else #invalid code
                  {code: ['is not valid']}
                end
              else #code missing
                {code: ['is missing']}
              end
            else #invalid token
              {token: ['is not valid']}
            end
          elsif data[:email]
            data[:password] = Devise.friendly_token unless data[:password]
            data[:password_confirmation] = data[:password] unless data[:password_confirmation]
            if (user = User.new(data)).valid?(context: :create)
              if (tkaptcha = TkAptcha.create(email: data[:email], data: data)).errors.blank?
                status = 200
                {token: tkaptcha.token}
              else
                tkaptcha.errors.to_json
              end
            else
              user.errors.to_json
            end
          else #bad request
            {token: ['is missing'], email: ['is missing']}
          end
      render json: response, status: status
    end

    protected

    def authorize
      key = params.delete('X-User-Access-Key')
      key = request.headers['X-User-Access-Key'] || key
      token = params.delete('X-User-Access-Token')
      token = request.headers['X-User-Access-Token'] || token
      user = User.where(key: key).first if key && token
      if user && Devise.secure_compare(user.token, token) && user.has_role?(:admin)
        Account.current = user.account
        return true
      end

      key = request.headers['X-Hub-Store']
      token = request.headers['X-Hub-Access-Token']
      unless Account.set_current_with_connection(key, token)
        responder = Cenit::Responder.new(@request_id, @webhook_body, 401)
        render json: responder, root: false, status: responder.code
        return false
      end
      true
    end

    def exception_handler(exception)
      responder = Cenit::Responder.new(@request_id, @webhook_body, 500)
      responder.backtrace = exception.backtrace.to_s
      render json: responder, root: false, status: responder.code
      return false
    end

    def find_item
      @item = klass.where(id: params[:id]).first
      unless @item.present?
        render json: {status: 'item not found'}
      end
    end

    def get_data_type_by_slug(slug)
      if slug
        @data_types[slug] ||=
            if @library_slug == 'setup'
              Setup::BuildInDataType["Setup::#{slug.camelize}"]
            else
              if @library_id.nil?
                lib = Setup::Library.where(slug: @library_slug).first
                @library_id = (lib && lib.id) || ''
              end
              if @library_id.present?
                Setup::DataType.where(slug: slug, library_id: @library_id).first
              else
                nil
              end
            end
      else
        nil
      end
    end

    def get_data_type(root)
      get_data_type_by_slug(root.singularize)
    end

    def get_model(root)
      if data_type = get_data_type(root)
        data_type.records_model
      else
        nil
      end
    end

    def klass
      @klass ||= get_model(@model)
    end

    def save_request_data
      @data_types ||= {}
      @request_id = request.uuid
      @webhook_body = request.body.read
      @library_slug = params[:library]
      @library_id = nil
      @model = params[:model]
      @payload =
          case request.content_type
            when 'application/json'
              JSONPayload
            when 'application/xml'
              XMLPayload
            else
              BasicPayload
          end.new(controller: self,
                  message: @webhook_body,
                  content_type: request.content_type)
      @criteria = params.to_hash.with_indifferent_access.reject { |key, _| %w(controller action library model id api).include?(key) }
    end

    private

    attr_reader :webhook_body

    class BasicPayload

      attr_reader :config
      attr_reader :create_options

      def initialize(config)
        @config =
            {
                create_method: case config[:content_type]
                                 when 'application/json'
                                   :create_from_json
                                 when 'application/xml'
                                   :create_from_xml
                                 else
                                   :create_from
                               end,
                message: ''
            }.merge(config || {})
        @data_type = (controller = config[:controller]).send(:get_data_type, (@root = controller.request.params[:model] || controller.request.headers['data-type'])) rescue nil
        @create_options = {create_collector: Set.new}
        create_options_keys.each { |option| @create_options[option.to_sym] = controller.request[option] }
      end

      def create_method
        config[:create_method]
      end

      def create_options_keys
        %w(filename)
      end

      def each_root(&block)
        block.call(@root, config[:message]) if block
      end

      def each(&block)
        if @data_type
          block.call(@data_type.slug, config[:message])
        else
          each_root(&block)
        end
      end

      def process_item(item, data_type)
        item
      end

      def data_type_for(root)
        @data_type && @data_type.slug == root ? @data_type : config[:controller].send(:get_data_type, root)
      end
    end

    class JSONPayload < BasicPayload

      def each_root(&block)
        JSON.parse(config[:message]).each { |root, message| block.call(root, message) } if block
      end

      def process_item(item, data_type)
        data_type.is_a?(Setup::FileDataType) ? item.to_json : item
      end
    end

    def create_options_keys
      super + %w(only)
    end

    class XMLPayload < BasicPayload

      def each_root(&block)
        if roots = Nokogiri::XML::DocumentFragment.parse(config[:message]).element_children
          roots.each do |root|
            if elements = root.element_children
              elements.each { |e| block.call(root.name, e) }
            end
          end
        end if block
      end

      def process_item(item, data_type)
        data_type.is_a?(Setup::FileDataType) ? item.to_xml : item
      end
    end
  end
end
