require File.dirname(__FILE__) + '/common_methods'
require File.dirname(__FILE__) + '/parser_methods'

module ActsAsSolr #:nodoc:

  module ClassMethods
    include CommonMethods
    include ParserMethods
    
    # Finds instances of a model. Terms are ANDed by default, can be overwritten 
    # by using OR between terms
    # 
    # Here's a sample (untested) code for your controller:
    # 
    #  def search
    #    results = Book.find_by_solr params[:query]
    #  end
    # 
    # You can also search for specific fields by searching for 'field:value'
    # 
    # ====options:
    # offset:: - The first document to be retrieved (offset)
    # limit:: - The number of rows per page
    # order:: - Orders (sort by) the result set using a given criteria:
    #
    #             Book.find_by_solr 'ruby', :order => 'description asc'
    # 
    # field_types:: This option is deprecated and will be obsolete by version 1.0.
    #               There's no need to specify the :field_types anymore when doing a 
    #               search in a model that specifies a field type for a field. The field 
    #               types are automatically traced back when they're included.
    # 
    #                 class Electronic < ActiveRecord::Base
    #                   acts_as_solr :fields => [{:price => :range_float}]
    #                 end
    # 
    # facets:: This option argument accepts the following arguments:
    #          fields:: The fields to be included in the faceted search (Solr's facet.field)
    #          query:: The queries to be included in the faceted search (Solr's facet.query)
    #          zeros:: Display facets with count of zero. (true|false)
    #          sort:: Sorts the faceted resuls by highest to lowest count. (true|false)
    #          browse:: This is where the 'drill-down' of the facets work. Accepts an array of
    #                   fields in the format "facet_field:term"
    #          mincount:: Replacement for zeros (it has been deprecated in Solr). Specifies the
    #                     minimum count necessary for a facet field to be returned. (Solr's
    #                     facet.mincount) Overrides :zeros if it is specified. Default is 0.
    #
    #          dates:: Run date faceted queries using the following arguments:
    #            fields:: The fields to be included in the faceted date search (Solr's facet.date).
    #                     It may be either a String/Symbol or Hash. If it's a hash the options are the
    #                     same as date_facets minus the fields option (i.e., :start:, :end, :gap, :other,
    #                     :between). These options if provided will override the base options.
    #                     (Solr's f.<field_name>.date.<key>=<value>).
    #            start:: The lower bound for the first date range for all Date Faceting. Required if
    #                    :fields is present
    #            end:: The upper bound for the last date range for all Date Faceting. Required if
    #                  :fields is prsent
    #            gap:: The size of each date range expressed as an interval to be added to the lower
    #                  bound using the DateMathParser syntax.  Required if :fields is prsent
    #            hardend:: A Boolean parameter instructing Solr what do do in the event that
    #                      facet.date.gap does not divide evenly between facet.date.start and facet.date.end.
    #            other:: This param indicates that in addition to the counts for each date range
    #                    constraint between facet.date.start and facet.date.end, other counds should be
    #                    calculated. May specify more then one in an Array. The possible options are:
    #              before:: - all records with lower bound less than start
    #              after:: - all records with upper bound greater than end
    #              between:: - all records with field values between start and end
    #              none:: - compute no other bounds (useful in per field assignment)
    #              all:: - shortcut for before, after, and between
    #            filter:: Similar to :query option provided by :facets, in that accepts an array of
    #                     of date queries to limit results. Can not be used as a part of a :field hash.
    #                     This is the only option that can be used if :fields is not present.
    # 
    # Example:
    # 
    #   Electronic.find_by_solr "memory", :facets => {:zeros => false, :sort => true,
    #                                                 :query => ["price:[* TO 200]",
    #                                                            "price:[200 TO 500]",
    #                                                            "price:[500 TO *]"],
    #                                                 :fields => [:category, :manufacturer],
    #                                                 :browse => ["category:Memory","manufacturer:Someone"]}
    # 
    #
    # Examples of date faceting:
    #
    #  basic:
    #    Electronic.find_by_solr "memory", :facets => {:dates => {:fields => [:updated_at, :created_at],
    #      :start => 'NOW-10YEARS/DAY', :end => 'NOW/DAY', :gap => '+2YEARS', :other => :before}}
    #
    #  advanced:
    #    Electronic.find_by_solr "memory", :facets => {:dates => {:fields => [:updated_at,
    #    {:created_at => {:start => 'NOW-20YEARS/DAY', :end => 'NOW-10YEARS/DAY', :other => [:before, :after]}
    #    }], :start => 'NOW-10YEARS/DAY', :end => 'NOW/DAY', :other => :before, :filter =>
    #    ["created_at:[NOW-10YEARS/DAY TO NOW/DAY]", "updated_at:[NOW-1YEAR/DAY TO NOW/DAY]"]}}
    #
    #  filter only:
    #    Electronic.find_by_solr "memory", :facets => {:dates => {:filter => "updated_at:[NOW-1YEAR/DAY TO NOW/DAY]"}}
    #
    #
    #
    # scores:: If set to true this will return the score as a 'solr_score' attribute
    #          for each one of the instances found. Does not currently work with find_id_by_solr
    # 
    #            books = Book.find_by_solr 'ruby OR splinter', :scores => true
    #            books.records.first.solr_score
    #            => 1.21321397
    #            books.records.last.solr_score
    #            => 0.12321548
    # 
    # lazy:: If set to true the search will return objects that will touch the database when you ask for one
    #        of their attributes for the first time. Useful when you're using fragment caching based solely on
    #        types and ids.
    #
    def find_by_solr(query, options={})
      data = parse_query(query, options)
      return parse_results(data, options) if data
    end
    
    # Finds instances of a model and returns an array with the ids:
    #  Book.find_id_by_solr "rails" => [1,4,7]
    # The options accepted are the same as find_by_solr
    # 
    def find_id_by_solr(query, options={})
      data = parse_query(query, options)
      return parse_results(data, {:format => :ids}) if data
    end
    
    # This method can be used to execute a search across multiple models:
    #   Book.multi_solr_search "Napoleon OR Tom", :models => [Movie]
    # 
    # ====options:
    # Accepts the same options as find_by_solr plus:
    # models:: The additional models you'd like to include in the search
    # results_format:: Specify the format of the results found
    #                  :objects :: Will return an array with the results being objects (default). Example:
    #                               Book.multi_solr_search "Napoleon OR Tom", :models => [Movie], :results_format => :objects
    #                  :ids :: Will return an array with the ids of each entry found. Example:
    #                           Book.multi_solr_search "Napoleon OR Tom", :models => [Movie], :results_format => :ids
    #                           => [{"id" => "Movie:1"},{"id" => Book:1}]
    #                          Where the value of each array is as Model:instance_id
    # scores:: If set to true this will return the score as a 'solr_score' attribute
    #          for each one of the instances found. Does not currently work with find_id_by_solr
    # 
    #            books = Book.multi_solr_search 'ruby OR splinter', :scores => true
    #            books.records.first.solr_score
    #            => 1.21321397
    #            books.records.last.solr_score
    #            => 0.12321548
    # 
    def multi_solr_search(query, options = {})
      models = multi_model_suffix(options)
      options.update(:results_format => :objects) unless options[:results_format]
      data = parse_query(query, options, models)
      
      if data.nil? or data.total_hits == 0
        return SearchResults.new(:docs => [], :total => 0)
      end

      result = find_multi_search_objects(data, options)
      if options[:scores] and options[:results_format] == :objects
        add_scores(result, data) 
      end
      SearchResults.new :docs => result, :total => data.total_hits
    end

    def find_multi_search_objects(data, options)
      result = []
      if options[:results_format] == :objects
        data.hits.each do |doc| 
          k = doc.fetch('id').first.to_s.split(':')
          result << k[0].constantize.find_by_id(k[1])
        end
      elsif options[:results_format] == :ids
        data.hits.each{|doc| result << {"id" => doc.values.pop.to_s}}
      end
      result
    end
    
    def multi_model_suffix(options)
      models = "AND (#{solr_configuration[:type_field]}:#{self.name}"
      models << " OR " + options[:models].collect {|m| "#{solr_configuration[:type_field]}:" + m.to_s}.join(" OR ") if options[:models].is_a?(Array)
      models << ")"
    end
    
    # returns the total number of documents found in the query specified:
    #  Book.count_by_solr 'rails' => 3
    # 
    def count_by_solr(query, options = {})        
      data = parse_query(query, options)
      data.total_hits
    end
            
    # It's used to rebuild the Solr index for a specific model. 
    #  Book.rebuild_solr_index
    # 
    # If batch_size is greater than 0, adds will be done in batches.
    # NOTE: If using sqlserver, be sure to use a finder with an explicit order.
    # Non-edge versions of rails do not handle pagination correctly for sqlserver
    # without an order clause.
    # 
    # If a finder block is given, it will be called to retrieve the items to index.
    # This can be very useful for things such as updating based on conditions or
    # using eager loading for indexed associations.
    def rebuild_solr_index(batch_size=0, &finder)
      finder ||= lambda { |ar, options| ar.find(:all, options.merge({:order => self.primary_key})) }
      start_time = Time.now

      if batch_size > 0
        items_processed = 0
        limit = batch_size
        offset = 0
        begin
          iteration_start = Time.now
          items = finder.call(self, {:limit => limit, :offset => offset})
          add_batch = items.collect { |content| content.to_solr_doc }
    
          if items.size > 0
            solr_add add_batch
            solr_commit
          end
    
          items_processed += items.size
          last_id = items.last.id if items.last
          time_so_far = Time.now - start_time
          iteration_time = Time.now - iteration_start         
          logger.info "#{Process.pid}: #{items_processed} items for #{self.name} have been batch added to index in #{'%.3f' % time_so_far}s at #{'%.3f' % (items_processed / time_so_far)} items/sec (#{'%.3f' % (items.size / iteration_time)} items/sec for the last batch). Last id: #{last_id}"
          offset += items.size
        end while items.nil? || items.size > 0
      else
        items = finder.call(self, {})
        items.each { |content| content.solr_save }
        items_processed = items.size
      end
      solr_optimize
      logger.info items_processed > 0 ? "Index for #{self.name} has been rebuilt" : "Nothing to index for #{self.name}"
    end

    #To reindex all elements, first deleting all of them and inserting them after
    def full_rebuild_solar_index(batch_size=0, &finder)
      ActsAsSolr::Post.execute(Solr::Request::Delete.new(:query => "#{self.solr_configuration[:type_field]}:#{self}")) 
      ActsAsSolr::Post.execute(Solr::Request::Commit.new)
      rebuild_solr_index(batch_size, &finder)
    end
    
    # Returns the query range to be added to the query
    def range_query( field_name, startsat, endsat )
      field = field_name_to_solr_field( field_name )
      if field[1][:sliced]
        case field[1][:type]
          when :range_double, "rd"
            double_range_query( field_name, startsat, endsat, field )
          when :date, "d"
            date_range_query( field_name, startsat, endsat, field )
        else
          raise "Sliced field #{field[1][:type]} not supported"
        end
      else
        _range_query( field_name, startsat, endsat, field )
      end
    end
    
    private
    def double_range_query( field_name, startsat, endsat, field )
      if startsat != "*" && endsat != "*"
        if startsat > endsat
          return double_range_query( field_name, endsat, startsat, field )
        end
        if startsat.ceil >= endsat.floor
          #The search has no whole int part so usual range query can be used
          return _range_query( field_name, startsat, endsat, field )
        end
      end
      v = [ startsat, 
        (startsat.respond_to?( :ceil )? startsat.ceil : startsat ), 
        (endsat.respond_to?( :floor )? endsat.floor : endsat ), 
        endsat ]
      field2 = field.dup
      field2[1] = field2[1].dup
      field2[1][:type] = :range_integer
      field2[1].delete(:sliced)
      filters = []
      filters << _range_query( field_name, v[0],  
        v[1], field) unless v[0] == v[1] || v[0] == v[1].to_f
      if v[1] == "*" || v[2] == "*" || v[1] < v[2]
        filters << _range_query( 
          field_name+"_ri", v[1], v[2], field2)
      end
      filters << _range_query( field_name, v[2], 
        v[3], field ) unless v[2] == v[3] || v[2].to_f == v[3]
      "( " + filters.join( " OR " ) + " )"
    end
    
    private
    def date_range_query( field_name, startsat, endsat, field )
      #Range not sliceable
      if startsat != "*" && endsat != "*"
        if startsat > endsat || startsat + 1.day > endsat
          return _range_query( field_name, startsat.utc.iso8601, endsat.utc.iso8601, field )
        end
      end
      
      startsat_day = if startsat == "*" || startsat.blank?
        startsat
      else
        t = (startsat.respond_to?( :utc )? startsat.utc : Time.parse(startsat).utc )
        pad = ( t.hour== 0 && t.min == 0 && t.sec == 0 ? 0 : 1 )
        Time.utc( t.year, t.month, t.day + pad)
      end
      endsat_day = if endsat == "*" || endsat.blank?
        endsat
      else
        time = (endsat.respond_to?( :utc )? endsat.utc : Time.parse(endsat).utc )
        Time.utc( endsat.year, endsat.month, endsat.day )
      end
      values = [ startsat, startsat_day, endsat_day, endsat ].collect do |v|
        if v == "*"
          v
        else
          v.respond_to?( :utc )? v.utc.iso8601 : v
        end
      end
      
      field2 = field.dup
      field2[1] = field2[1].dup
      field2[1].delete(:sliced)
      filters = []
      filters << _range_query( field_name, values[0], 
        values[1], field) unless values[0] == values[1]
      filters << _range_query( field_name+"_day_d", values[1], 
        values[2], field2) unless values[1] == values[2]
      filters << _range_query( field_name, values[2], 
        values[3], field ) unless values[2] == values[3]
      "( " + filters.join( " OR " ) + " )"
    end
    
    def _range_query( field_name, startsat, endsat, field )
      range = [ startsat, endsat ].map{|v| v.respond_to?( :to_solr ) ? v.to_solr : v }
      map_query_to_fields( "#{field_name}:[#{ range[0] } TO #{ range[1] }]" )
    end
    
  end
  
end