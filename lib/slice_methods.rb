module ActsAsSolr #:nodoc:
  
  module SliceMethods
    
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
      slices = field[1][:sliced]
      if startsat != "*" && endsat != "*"
        if startsat > endsat
          return double_range_query( field_name, endsat, startsat, field )
        end
      end
      if slices == 1
        if startsat != "*" && endsat != "*"
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
            field_name+"_ri", v[1], (v[2]!="*" ? v[2] - 1 : v[2]) , field2)
        end
        filters << _range_query( field_name, v[2], 
          v[3], field ) unless v[2] == "*" 
        "( " + filters.join( " OR " ) + " )"
      elsif slices.respond_to?( :each )
        n_sliced_double_range_query( field_name, startsat, endsat, field )
      else
        n_sliced_double_range_query( field_name, startsat, endsat, field )
      end
    end

    # Constructs a group of solr conditions that coverage exactly the range
    # Taking advantage of the fields available
    def n_sliced_double_range_query( field_name, startsat, endsat, field )
      filters = []
      openstart = startsat == "*"
      openend = endsat == "*"
      slices = rd_slice_list( field, field_name )
      startsat = BigDecimal.new( startsat.to_s ) unless openstart
      endsat = BigDecimal.new( endsat.to_s ) unless openend

      range = if ( openstart || openend ) then
        if openstart && !openend then
          filters << _range_query( field_name+"_ri",
            "*", (endsat.floor - 1).to_i , slices.last[1] )
          ( endsat.floor.to_f .. endsat )
        elsif !openstart && openend 
          filters << _range_query( field_name+"_ri", 
            startsat.ceil.to_i,  "*", slices.last[1] )
          ( startsat .. startsat.ceil.to_f )
        else
          nil #If the range is totally open, we don't need to filter anything
        end
      else
        ( startsat .. endsat )
      end
      return if range.nil?
      range = FloatRange.new( range.first, range.last)
      #Bucle to eat the range
      ranges = [ range ]
      original_range = range
      while ranges.size > 0 do
        ranges_it = ranges.dup
        ranges_it.each_with_index do |range, idx|
          sliced = false
          slices.each do |dec, f, fn |
            unless sliced
              # See if the range have some parts that can be eaten by this dec
              if range.has_a_part_of( dec ) then
                rc = range.range_covered_by_decimals( dec )
                ranges.delete( range )
                ranges2 = range.substract rc
                ranges += ranges2.compact
                offset = 0
                offset = 1.0 / 10**dec unless dec == :all
                if dec == 0
                  filters << _range_query( fn, rc.first.to_i, (rc.last - offset).to_i, f )
                else
                  filters << _range_query( fn, rc.first, rc.last - offset, f )
                end
                if offset > 0.0 && (!openend || (openend && rc.last != original_range.last) )
                  ranges << FloatRange.new( rc.last, rc.last ) if offset > 0.0
                end
                sliced = true
              end
            end
          end
        end
        #Remove the unitary ranges that are not original range edges
        ranges = ranges.select do | r |
          !( r.length == 0 && (
              r.first != original_range.first && r.last != original_range.last))
        end
      end
      "( " + filters.join( " OR " ) + " )"
    end

    #Construct the slice list
    def rd_slice_list( field, field_name )
      slice = field[1][:sliced]
      # Int field type
      int_field = field.dup
      int_field[1] = int_field[1].dup
      int_field[1][:type] = :range_integer
      int_field[1].delete(:sliced)

      res = [ [ 0, int_field, field_name+"_ri"] ]
      if slice == 2
        slice = [ 4 ]
      end
      slice.each do |d|
        res << [ d, field, field_name+"_#{d}d_rd"]
      end
      res << [ :all, field, field_name ]
      res
    end
    
    class FloatRange < Range

      def initialize( first, last )
        first = BigDecimal.new( first.to_s ) if first != "*"
        last = BigDecimal.new( last.to_s ) if last != "*"
        super( first, last)
      end
      
      def length
        self.last - self.first 
      end
      
      def intersect( other )
        start = [ self.first, other.first].max
        finish = [ self.last, other.last].min
        if( start <= finish )
          self.class.new( start, finish )
        end
      end
      
      def union( other )
        self.new( [ self.first, other.first].min, [ self.last, other.last].max )
      end
      
      def split( point )
        unless self.include? point
          [ self.new( self.first, point ),
          self.new( point, self.last ) ]
        end
      end
      
      #True when it contains a part that can ... WHAT?!!?!?
      def has_a_part_of( d )
        return true if d == :all
        part = range_covered_by_decimals( d )
        part.nil? ? false : part.length > 0.0
      end
      
      def range_covered_by_decimals( d )
        return self if d == :all
        move = BigDecimal.new("10.0") ** d.to_i
        if !(self.first * move).respond_to? :ceil
          require "ruby-debug"
          debugger
        end
        pair = [ (self.first * move).ceil / move,
          (self.last * move).floor / move ]
        self.class.new( *pair ) unless pair[0] > pair[1]
      end
      
      #Substraction of ranges returns an array of ranges
      def substract( other )
        if i = self.intersect( other )
          if i == self
            [ nil ]
          else
            [ self.class.new( self.first, i.first ),
            self.class.new( i.last, self.last ) ].select{|r|r.length > 0.0 }
          end
        else
          [ self ]
        end
      end
    end
  end
end
