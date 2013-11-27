# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

module NewRelic
  module TestHelpers
    module MongoMetricBuilder
      def build_test_metrics(name, web = true)
        NewRelic::Agent::MongoMetricTranslator.build_metrics(
          :name => name,
          :collection => @collection_name,
          :web => web
        )
      end
    end
  end
end
