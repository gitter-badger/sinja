# frozen_string_literal: true
module Sinja
  module RelationshipRoutes
    module HasOne
      def self.registered(app)
        app.def_action_helper(app, :pluck, :roles)
        app.def_action_helper(app, :prune, :roles)
        app.def_action_helper(app, :graft, %i[roles sideload_on])

        app.head '' do
          unless relationship_link?
            allow :get=>:pluck
          else
            allow :get=>:show, :patch=>[:prune, :graft]
          end
        end

        app.get '', :actions=>:show do
          pass unless relationship_link?

          serialize_linkage
        end

        app.get '', :qparams=>%i[include fields], :actions=>:pluck do
          serialize_model(*pluck)
        end

        app.patch '', :nullif=>proc(&:nil?), :actions=>:prune do
          serialize_linkage?(*prune)
        end

        app.patch '', :actions=>:graft do
          serialize_linkage?(*graft(data))
        end
      end
    end
  end
end
