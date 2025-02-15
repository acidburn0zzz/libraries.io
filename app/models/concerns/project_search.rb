# frozen_string_literal: true
module ProjectSearch
  # Whenever a PackageManager::Base platform is removed, it's easier for now to
  # just add it to this list, until the records/indices are cleared out of that platform.
  # NB these are the casings from the database, which sometimes don't match the PackageManager::Base
  # formatted_name casings, e.g. Pypi vs PyPI
  REMOVED_PLATFORMS = %w(Sublime Wordpress Atom PlatformIO Shards Emacs Jam)

  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model

    index_name "projects-#{Rails.env}"

    FIELDS = ['name^2', 'exact_name^2', 'extra_searchable_names^2', 'repo_name', 'description', 'homepage', 'language', 'keywords_array', 'normalized_licenses', 'platform']

    settings index: { number_of_shards: 3, number_of_replicas: 1 } do
      mapping do
        indexes :name, type: 'string', analyzer: 'snowball', boost: 6
        indexes :exact_name, type: 'string', index: :not_analyzed, boost: 2
        indexes :extra_searchable_names, type: 'string', index: :not_analyzed, boost: 2

        indexes :description, type: 'string', analyzer: 'snowball'
        indexes :homepage, type: 'string'
        indexes :repository_url, type: 'string'
        indexes :repo_name, type: 'string'
        indexes :latest_release_number, type: 'string', analyzer: 'keyword'
        indexes :keywords_array, type: 'string', analyzer: 'keyword'
        indexes :language, type: 'string', analyzer: 'keyword'
        indexes :normalized_licenses, type: 'string', analyzer: 'keyword'
        indexes :platform, type: 'string', analyzer: 'keyword'
        indexes :status, type: 'string', index: :not_analyzed

        indexes :created_at, type: 'date'
        indexes :updated_at, type: 'date'
        indexes :latest_release_published_at, type: 'date'

        indexes :rank, type: 'integer'
        indexes :stars, type: 'integer'
        indexes :dependents_count, type: 'integer'
        indexes :dependent_repos_count, type: 'integer'
        indexes :contributions_count, type: 'integer'
      end
    end

    after_commit lambda { __elasticsearch__.index_document if previous_changes.any? }, on: [:create, :update], prepend: true
    after_commit lambda { __elasticsearch__.delete_document rescue nil },  on: :destroy

    def as_indexed_json(_options = {})
      as_json(methods: [:stars, :repo_name, :exact_name, :extra_searchable_names, :contributions_count, :dependent_repos_count]).merge(keywords_array: keywords)
    end

    def dependent_repos_count
      read_attribute(:dependent_repos_count) || 0
    end

    def exact_name
      name
    end

    def extra_searchable_names
      if platform == "Maven"
        name.split(":")
      elsif platform == "Clojars"
        name.split("/")
      else
        []
      end
    end

    def marshal_dump
      instance_variables.reject{|m| :__elasticsearch__ == m}.inject({}) do |vars, attr|
        vars[attr] = instance_variable_get(attr)
        vars
      end
    end

    def marshal_load(hash)
      hash.each do |attr, value|
        instance_variable_set(attr, value)
      end
    end

    def self.facets(options = {})
      Rails.cache.fetch "facet:#{options.to_s.gsub(/\W/, '')}", expires_in: 1.hour, race_condition_ttl: 2.minutes do
        search('', options).response.aggregations
      end
    end

    def self.facets_options(facet_limit, options)
      {
        language: {
          aggs: {
            language: {
              terms: {
                field: "language",
                size: facet_limit
              },
            }
          },
          filter: {
            bool: {
              must: filter_format(options[:filters], :language)
            }
          }
        },
        licenses: {
          aggs:{
            licenses:{
              terms: {
                field: "normalized_licenses",
                size: facet_limit
              }
            }
          },
          filter: {
            bool: {
              must: filter_format(options[:filters], :normalized_licenses)
            }
          }
        }
      }
    end

    def self.search(query, options = {})
      facet_limit = options.fetch(:facet_limit, 36)
      options[:filters] ||= []
      search_definition = {
        query: {
          function_score: {
            query: {
              filtered: {
                 query: {match_all: {}},
                 filter:{
                   bool: {
                     must: [],
                     must_not: [
                       { term: { "status" => "Hidden" } },
                       { term: { "status" => "Removed" } },
                       { terms: { "platform" => REMOVED_PLATFORMS } }
                     ]
                  }
                }
              }
            },
            field_value_factor: {
              field: "rank",
              "modifier": "square"
            }
          }
        },
        filter: { bool: { must: [] } },
      }

      unless options[:api]
        search_definition[:aggs] = {
          platforms: facet_filter(:platform, facet_limit, options),
          languages: facet_filter(:language, facet_limit, options),
          keywords: facet_filter(:keywords_array, facet_limit, options),
          licenses: facet_filter(:normalized_licenses, facet_limit, options)
        }
        if query.present?
          search_definition[:suggest] = {
            did_you_mean: {
              text: query,
              term: {
                size: 1,
                field: "name"
              }
            }
          }
        end
      end

      search_definition[:sort]  = { (options[:sort] || '_score') => (options[:order] || 'desc') }
      search_definition[:query][:function_score][:query][:filtered][:filter][:bool][:must] = filter_format(options[:filters])

      if query.present?
        search_definition[:query][:function_score][:query][:filtered][:query] = query_options(query, FIELDS)
      elsif options[:sort].blank?
        search_definition[:sort]  = [{'rank' => 'desc'}, {'stars' => 'desc'}]
      end

      if options[:prefix].present?
        search_definition[:query][:function_score][:query][:filtered][:query] = {
          prefix: { exact_name: original_query }
        }
        search_definition[:sort]  = [{'rank' => 'desc'}, {'stars' => 'desc'}]
      end

      __elasticsearch__.search(search_definition)
    end

    def self.query_options(query, fields)
      {
        multi_match: {
          query: query,
          fields: fields,
          fuzziness: 1.2,
          slop: 2,
          type: 'cross_fields',
          operator: 'and'
        }
      }
    end

    def self.filter_format(filters, except = nil)
      filters.select { |k, v| v.present? && k != except }.map do |k, v|
        Array(v).map { { terms: { k => v.split(',') } } }
      end
    end

    def self.facet_filter(name, limit, options)
      {
        aggs: {
          name.to_s => {
            terms: {
              field: name.to_s,
              size: limit
            }
          }
        },
        filter: {
          bool: {
            must: filter_format(options[:filters], name.to_sym)
          }
        }
      }
    end
  end
end
