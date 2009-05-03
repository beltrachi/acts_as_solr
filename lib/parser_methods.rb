module ActsAsSolr #:nodoc:
  
  module ParserMethods
    
    protected    
    
    # Method used by mostly all the ClassMethods when doing a search
    def parse_query(query=nil, options={}, models=nil)
      options = options.symbolize_keys
      valid_options = [:offset, :limit, :facets, :models, :results_format, :order, :scores, :operator, :include, :lazy]
      query_options = {}
      return nil if (query.nil? || query.strip == '')
      raise "Invalid parameters: #{(options.keys - valid_options).map(&:inspect).join(',')}" unless (options.keys - valid_options).empty?
      
      begin
        Deprecation.validate_query(options)
        query_options[:start] = options[:offset]
        query_options[:rows] = options[:limit]
        query_options[:operator] = options[:operator]
        
        # first steps on the facet parameter processing
        if options[:facets]
          query_options[:facets] = {}
          query_options[:facets][:limit] = -1  # TODO: make this configurable
          query_options[:facets][:sort] = :count if options[:facets][:sort]
          query_options[:facets][:mincount] = 0
          query_options[:facets][:mincount] = 1 if options[:facets][:zeros] == false
          # override the :zeros (it's deprecated anyway) if :mincount exists
          query_options[:facets][:mincount] = options[:facets][:mincount] if options[:facets][:mincount]
          query_options[:facets][:fields] = options[:facets][:fields].collect{|k| "#{k}_facet"} if options[:facets][:fields]
          query_options[:filter_queries] = replace_types([*options[:facets][:browse]].collect{|k| "#{k.sub!(/ *: */,"_facet:")}"}) if options[:facets][:browse]
          query_options[:facets][:queries] = replace_types(options[:facets][:query].collect{|k| "#{k.sub!(/ *: */,"_t:")}"}) if options[:facets][:query]
          
          
          if options[:facets][:dates]
            query_options[:date_facets] = {}
            # if options[:facets][:dates][:fields] exists then :start, :end, and :gap must be there
            if options[:facets][:dates][:fields]
              [:start, :end, :gap].each { |k| raise "#{k} must be present in faceted date query" unless options[:facets][:dates].include?(k) }
              query_options[:date_facets][:fields] = []
              options[:facets][:dates][:fields].each { |f|
                if f.kind_of? Hash
                  key = f.keys[0]
                  query_options[:date_facets][:fields] << {"#{key}_d" => f[key]}
                  validate_date_facet_other_options(f[key][:other]) if f[key][:other]
                else
                  query_options[:date_facets][:fields] << "#{f}_d"
                end
              }
            end
            
            query_options[:date_facets][:start]   = options[:facets][:dates][:start] if options[:facets][:dates][:start]
            query_options[:date_facets][:end]     = options[:facets][:dates][:end] if options[:facets][:dates][:end]
            query_options[:date_facets][:gap]     = options[:facets][:dates][:gap] if options[:facets][:dates][:gap]
            query_options[:date_facets][:hardend] = options[:facets][:dates][:hardend] if options[:facets][:dates][:hardend]
            query_options[:date_facets][:filter]  = replace_types([*options[:facets][:dates][:filter]].collect{|k| "#{k.sub!(/ *:(?!\d) */,"_d:")}"}) if options[:facets][:dates][:filter]

            if options[:facets][:dates][:other]
              validate_date_facet_other_options(options[:facets][:dates][:other])
              query_options[:date_facets][:other]   = options[:facets][:dates][:other]
            end
            
          end          
        end
        
        if models.nil?
          # TODO: use a filter query for type, allowing Solr to cache it individually
          models = "#{solr_type_condition}"
          field_list = solr_configuration[:primary_key_field]
        else
          field_list = "id"
        end
        
        query_options[:field_list] = [field_list, 'score']
        
        unless query.nil? || query.empty? || query == '*'
          query = "(#{map_query_to_fields(query)}) AND #{models}"
        else
          query = "#{models}"
        end
        query_options[:query] = query

        logger.debug "SOLR query: #{query.inspect}" if defined? logger

        unless options[:order].blank?
          order = map_order_to_fields(options[:order])
          query_options[:query] << ';' << order
        end
        
        ActsAsSolr::Post.execute(Solr::Request::Standard.new(query_options))
      rescue
        raise "There was a problem executing your search: #{$!} in #{$!.backtrace.first}"
      end            
    end
    
    def solr_type_condition
      subclasses.inject("(#{solr_configuration[:type_field]}:#{self.name.gsub ':', '\:'}") do |condition, subclass|
        condition << " OR #{solr_configuration[:type_field]}:#{subclass.name.gsub ':', '\:'}"
      end << ')'
    end
   
    # map index fields to the appropriate lucene_fields
    # "title:(a fish in my head)" => "title_t:(a fish in my head)"
    # it should avoid mapping to _sort fields
    def map_query_to_fields(query)
      #{query.gsub(/ *: */,"_t:")}
      query.gsub(/(\w+)\s*:\s*/) do |match| # sets $1 in the block
        field_name = $1
        field_name = field_name_to_lucene_field(field_name)
        "#{field_name}:"
      end
    end
    
    def map_order_to_fields(string)
      string.split(",").map do |clause|
        field_name, direction = clause.strip.split(/\s+/)
        field_name = field_name_to_lucene_field(field_name, :sort) unless field_name == "score"
        direction ||= "asc"
        
        "#{field_name} #{direction.downcase}"
      end.join(",")
    end
      
    # Parses the data returned from Solr
    def parse_results(solr_data, options = {})
      find_options = options.slice(:include)
      results = {
        :docs => [],
        :total => 0
      }
      configuration = {
        :format => :objects
      }
      results.update(:facets => {'facet_fields' => []}) if options[:facets]
      return SearchResults.new(results) if !solr_data || solr_data.total == 0
      
      configuration.update(options) if options.is_a?(Hash)

      ids = solr_data.hits.collect {|doc| doc["#{solr_configuration[:primary_key_field]}"]}.flatten
      result = find_objects(ids, options, configuration)

      add_scores(result, solr_data) if configuration[:format] == :objects && options[:scores]
      
      # added due to change for solr 1.3 ruby return struct for facet_fields is an array not hash
      # require "ruby-debug"
      # debugger
      # if options[:facets] && !solr_data.data['facet_counts']['facet_fields'].empty?
        # facet_fields = solr_data.data['facet_counts']['facet_fields']
        # solr_data.data['facet_counts']['facet_fields'] = {}
        # facet_fields.each do |name, values|
          # solr_data.data['facet_counts']['facet_fields'][name] = {}
          # values.length.times do | a |
            # if a.odd?
              # solr_data.data['facet_counts']['facet_fields'][name][values[a-1]] = values[a]
            # else
              # solr_data.data['facet_counts']['facet_fields'][name][values[a]]
            # end
          # end    
        # end
      # end
      
      results.update(:facets => solr_data.data['facet_counts']) if options[:facets]
      results.update({:docs => result, :total => solr_data.total, :max_score => solr_data.max_score, :query_time => solr_data.data['responseHeader']['QTime']})
      SearchResults.new(results)
    end
    
    def find_objects(ids, options, configuration)
      result = if configuration[:lazy] && configuration[:format] != :ids
        ids.collect {|id| ActsAsSolr::LazyDocument.new(id, self)}
      elsif configuration[:format] == :objects
        conditions = [ "#{self.table_name}.#{primary_key} in (?)", ids ]
        find_options = {:conditions => conditions}
        find_options[:include] = options[:include] if options[:include]
        result = reorder(self.find(:all, find_options), ids)
      else
        ids
      end
        
      result
    end

    # Reorders the instances keeping the order returned from Solr
    def reorder(things, ids)
      ordered_things = Array.new(things.size)
      raise "Out of sync! Found #{ids.size} items in index, but only #{things.size} were found in database!" unless things.size == ids.size
      things.each do |thing|
        position = ids.index(thing.id)
        ordered_things[position] = thing
      end
      ordered_things
    end

    # Replaces the field types based on the types (if any) specified
    # on the acts_as_solr call
    def replace_types(strings, include_colon=true)
      suffix = include_colon ? ":" : ""
      if configuration[:solr_fields]
        configuration[:solr_fields].each do |name, options|
          solr_name = options[:as] || name.to_s
          solr_type = get_solr_field_type(options[:type])
          field = "#{solr_name}_#{solr_type}#{suffix}"
          strings.each_with_index {|s,i| strings[i] = s.gsub(/#{solr_name.to_s}_t#{suffix}/,field) }
        end
      end
      if configuration[:solr_includes]
        configuration[:solr_includes].each do |association, options|
          solr_name = options[:as] || association.to_s.singularize
          solr_type = get_solr_field_type(options[:type])
          field = "#{solr_name}_#{solr_type}#{suffix}"
          strings.each_with_index {|s,i| strings[i] = s.gsub(/#{solr_name.to_s}_t#{suffix}/,field) }
        end
      end
      strings
    end
    
    # Adds the score to each one of the instances found
    def add_scores(results, solr_data)
      with_score = []
      solr_data.hits.each do |doc|
        with_score.push([doc["score"], 
          results.find {|record| scorable_record?(record, doc) }])
      end
      with_score.each do |score, object| 
        class << object; attr_accessor :solr_score; end
        object.solr_score = score
      end
    end

    def scorable_record?(record, doc)
      doc_id = doc["#{solr_configuration[:primary_key_field]}"]
      if doc_id.nil?
        doc_id = doc["id"]
        "#{record.class.name}:#{record_id(record)}" == doc_id.first.to_s
      else
        record_id(record).to_s == doc_id.to_s
      end
    end
    
    def validate_date_facet_other_options(options)
      valid_other_options = [:after, :all, :before, :between, :none]
      options = [options] unless options.kind_of? Array
      bad_options = options.map {|x| x.to_sym} - valid_other_options
      raise "Invalid option#{'s' if bad_options.size > 1} for faceted date's other param: #{bad_options.join(', ')}. May only be one of :after, :all, :before, :between, :none" if bad_options.size > 0
    end

    # looks through the configured :solr_fields, and chooses the most appropriate
    # pass it :sort if you would prefer a :sort_field
    # or pass it :text if that's your prefered type
    def field_name_to_solr_field(field_name, favoured_types=nil)
      favoured_types = Array(favoured_types)

      solr_fields = configuration[:solr_fields].select do |field, options|
        field.to_s == field_name.to_s
      end
      prefered, secondary = solr_fields.partition do |field, options|
        favoured_types.include?(options[:type])
      end
      prefered.first || secondary.first # will return nil if no matches
    end
    
    # takes a normalized field... ie. [:field, {:type => :text}]
    # gets us the lucene field name "field_t"
    def solr_field_to_lucene_field(normalized_field)
      field_name, options = normalized_field
      field_type = options[:type]
      "#{field_name}_#{get_solr_field_type(field_type)}"
    end
    
    # "title" => "title_t", or "title_sort"
    # "score" => "score" -- SPECIAL CASE
    def field_name_to_lucene_field(field_name, favoured_types=[:string, :text])
      if normalized_field = field_name_to_solr_field(field_name, favoured_types)
        solr_field_to_lucene_field(normalized_field)
      else
        field_name.to_s
      end
    end
    
  end
end
