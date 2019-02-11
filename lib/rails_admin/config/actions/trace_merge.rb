module RailsAdmin
  module Config
    module Actions
      class TraceMerge < RailsAdmin::Config::Actions::Base

        register_instance_option :visible? do
          authorized? && (obj = bindings[:object]) && obj.previous
        end

        register_instance_option :only do
          Mongoid::Tracer::Trace
        end

        register_instance_option :member do
          true
        end

        register_instance_option :route_fragment do
          'merge'
        end

        register_instance_option :controller do
          proc do
            if @object
              @object.merge_prev
              redirect_to rails_admin.show_path(
                  model_name: @abstract_model.to_param,
                  id: @object.id
              )
            else
              redirect_to back_or_index
            end

=begin
            rails_admin.new_path(model_name: Setup::Filter.to_s.underscore.gsub('/', '~'), params: { json_token: token })
            if @object.next
              redirect_to v(
                model_name: @abstract_model.to_param,
                id: @object.next.id
              )
            else
              redirect_to back_or_index
            end
=end
          end
        end

        register_instance_option :link_icon do
          'fa fa-level-up'
        end
      end
    end
  end
end