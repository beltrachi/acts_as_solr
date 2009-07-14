require File.dirname(__FILE__) + '/test_helper'
require 'class_methods'
require 'search_results'
require 'active_support'

class User
  attr_accessor :name, :id
  def self.find(*args)
    @paul ||= User.new
    @paul.name = "Paul"
    @paul.id = 1
    @paul
  end
  
  def self.find_by_id(id)
    find
  end
  
  def self.primary_key
    "id"
  end
  
  def created_at
    Time.now
  end
end

class ClassMethodsTest < Test::Unit::TestCase
  include ActsAsSolr::ClassMethods
  include ActsAsSolr::SliceMethods
  
  def solr_configuration
    @solr_configuration ||= {:type_field => "type_t", :primary_key_field => "id"}
  end
  
  def assert_include( expect, result, message = "")
    assertion = if expect.is_a? Regexp
      result.match expect
    else
      result.include?( expect )
    end
    assert assertion, "The string [ #{result} ] does not contain [ #{expect} ]"
  end
  
  context "when multi-searching" do
    setup do
      stubs(:name).returns("User")
    end
    
    should "include the type field in the query" do
      expects(:parse_query).with("name:paul", {:results_format => :objects}, "(type_t:User)")
      multi_solr_search("name:paul")
    end
    
    should "add all models in the query" do
      expects(:parse_query).with("name:paul", {:results_format => :objects, :models => ["Movie", "DVD"]}, "(type_t:User OR type_t:Movie OR type_t:DVD)")
      multi_solr_search("name:paul", :models => ["Movie", "DVD"])
    end
    
    should "return an empty result set if no data was returned" do
      stubs(:parse_query).returns(nil)
      result = multi_solr_search("name:paul")
      assert_equal 0, result.docs.size
    end
    
    should "return an empty result set if no results were found" do
      stubs(:parse_query).returns(stub(:total_hits => 0, :hits => []))
      result = multi_solr_search("name:paul")
      assert_equal 0, result.docs.size
    end
    
    context "with results" do
      should "find the objects in the database" do
        stubs(:parse_query).returns(stub(:total_hits => 1, :hits => ["score" => 0.12956427, "id" => ["User:1"]]))
        result = multi_solr_search("name:paul")
        
        assert_equal(User.find, result.docs.first)
        assert_equal 1, result.docs.size
      end
      
      context "when requesting ids" do
        should "return only ids" do
          stubs(:parse_query).returns(stub(:total_hits => 1, :hits => ["score" => 0.12956427, "id" => ["User:1"]]))
          result = multi_solr_search("name:paul", :results_format => :ids)
          assert_equal "User:1", result.docs.first["id"]
        end
      end
      
      context "with scores" do
        setup do
          solr_configuration[:primary_key_field] = nil
        end
        
        should "add an accessor with the solr score" do
          stubs(:parse_query).returns(stub(:total_hits => 1, :hits => ["score" => 0.12956427, "id" => ["User:1"]]))
          result = multi_solr_search("name:paul", :scores => true)
          assert_equal 0.12956427, result.docs.first.solr_score
        end
      end
    end
  end
  
  context "when searching date ranges" do
    setup do
      stubs(:name).returns("User")
      @solr_configuration = {:type_field => "type_t", :primary_key_field => "id",}
      stubs(:configuration).returns( {:solr_fields => { :created_at => { :type => :date, :sliced => 1 } } } )
    end
    
    should "include the type field in the query" do
      result = range_query( "created_at" , Time.parse("2009-01-01T12:00:00Z"), Time.parse("2009-01-12T12:00:00Z") )
      assert_include( "[2009-01-01T12:00:00Z TO 2009-01-02T00:00:00Z]", result)
      assert_include( "created_at_day_d:[2009-01-02T00:00:00Z TO 2009-01-12T00:00:00Z]", result)
      assert_include( "[2009-01-12T00:00:00Z TO 2009-01-12T12:00:00Z]", result)
    end

    should "not include the first part if its empty" do
      result = range_query( "created_at" , Time.parse("2009-01-02T00:00:00Z"), Time.parse("2009-01-12T12:00:00Z") )
      assert !result.include?("[2009-01-02T00:00:00Z TO 2009-01-02T00:00:00Z]")
      assert_include( "created_at_day_d:[2009-01-02T00:00:00Z TO 2009-01-12T00:00:00Z]", result)
      assert_include( "[2009-01-12T00:00:00Z TO 2009-01-12T12:00:00Z]", result)
      assert result.scan(/created_at/).size == 2
    end

    should "not include the last part if its empty" do
      result = range_query( "created_at" , Time.parse("2009-01-01T12:00:00Z"), Time.parse("2009-01-12T00:00:00Z") )
      assert_include( "[2009-01-01T12:00:00Z TO 2009-01-02T00:00:00Z]", result)
      assert_include( "created_at_day_d:[2009-01-02T00:00:00Z TO 2009-01-12T00:00:00Z]", result)
      assert !result.include?("[2009-01-12T00:00:00Z TO 2009-01-12T12:00:00Z]")
      assert result.scan(/created_at/).size == 2
    end

    should "not include the first and the last part if its empty" do
      result = range_query( "created_at" , Time.parse("2009-01-01T00:00:00Z"), Time.parse("2009-01-12T00:00:00Z") )
      assert !result.include?("[2009-01-01T00:00:00Z TO 2009-01-01T00:00:00Z]")
      assert_include( "created_at_day_d:[2009-01-01T00:00:00Z TO 2009-01-12T00:00:00Z]", result)
      assert !result.include?("[2009-01-12T00:00:00Z TO 2009-01-12T00:00:00Z]")
      assert result.scan(/created_at/).size == 1
    end

    should "not do the dayquery when the range is lower than a whole day" do
      result = range_query( "created_at" , Time.parse("2009-01-01T12:00:00Z"), Time.parse("2009-01-01T13:00:00Z") )
      assert_include( "[2009-01-01T12:00:00Z TO 2009-01-01T13:00:00Z]", result)
      assert !result.include?("created_at_day")
      assert result.scan(/created_at/).size == 1
    end

    should "not include the day query when its not needed" do
      result = range_query( "created_at" , Time.parse("2009-01-01T12:00:00Z"), Time.parse("2009-01-02T13:00:00Z") )
      assert !result.include?("created_at_day_d")
      assert_include( "[2009-01-01T12:00:00Z TO 2009-01-02T00:00:00Z]", result)
      assert_include( "[2009-01-02T00:00:00Z TO 2009-01-02T13:00:00Z]", result)
      assert result.scan(/created_at/).size == 2
    end

    context "on open ranges" do
      should " open end " do
        result = range_query( "created_at" , Time.parse("2009-01-01T12:00:00Z"), "*" )
        assert_include( "[2009-01-01T12:00:00Z TO 2009-01-02T00:00:00Z]", result)
        assert_include( "[2009-01-02T00:00:00Z TO *]", result)
        assert result.scan(/created_at/).size == 2
      end

      should " open start " do
        result = range_query( "created_at" , "*", Time.parse("2009-01-01T12:00:00Z") )
        assert_include( "[2009-01-01T00:00:00Z TO 2009-01-01T12:00:00Z]", result)
        assert_include( "created_at_day_d:[* TO 2009-01-01T00:00:00Z]", result)
        assert result.scan(/created_at/).size == 2
      end

      should " open start day sharp" do
        result = range_query( "created_at" , "*", Time.parse("2009-01-01T00:00:00Z") )
        assert_include( "created_at_day_d:[* TO 2009-01-01T00:00:00Z]", result)
        assert result.scan(/created_at/).size == 1
      end

      should " open end day sharp" do
        result = range_query( "created_at" , Time.parse("2009-01-01T00:00:00Z"), "*" )
        assert_include( "created_at_day_d:[2009-01-01T00:00:00Z TO *]", result)
        assert result.scan(/created_at/).size == 1
      end
    end
  end

  context "when searching range_double ranges" do
    setup do
      stubs(:name).returns("User")
      @solr_configuration = {:type_field => "type_t", :primary_key_field => "id",}
      stubs(:configuration).returns( {:solr_fields => { :lat => { :type => :range_double, :sliced => 1 } } } )
    end
    
    should "query 3 fields separated by or" do
      result = range_query( "lat" , 1.1 , 10.3 )
      assert_include( "lat_rd:[1.1 TO 2]", result)
      assert_include( "lat_ri:[2 TO 9]", result)
      assert_include( "lat_rd:[10 TO 10.3]", result)
      assert result.scan(/lat_rd/).size == 2
      assert result.scan(/ OR /).size == 2
    end
    
    should "query starts with int" do
      result = range_query( "lat" , 1.0 , 10.3 )
      assert_include( "lat_ri:[1 TO 9]", result)
      assert_include( "lat_rd:[10 TO 10.3]", result)
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 1
    end
    
    should "query ends with int" do
      result = range_query( "lat" , 1.8 , 10 )
      assert_include( "lat_rd:[1.8 TO 2]", result) #
      assert_include( "lat_ri:[2 TO 9]", result) # gets 2.00 to 9.999...
      assert_include( "lat_rd:[10 TO 10]", result) # gets 10.000... to 10.000
      assert result.scan(/lat_/).size == 3
      assert result.scan(/ OR /).size == 2
    end
    
    should "query no range" do
      result = range_query( "lat" , 1.8 , 1.8 )
      assert_include( "lat_rd:[1.8 TO 1.8]", result)
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 0
    end

    should "query no int part used" do
      result = range_query( "lat" , 1.8 , 1.9 )
      assert_include( "lat_rd:[1.8 TO 1.9]", result)
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 0
    end

    should "query reverse range is reverted" do
      result = range_query( "lat" , 1.7 , 1.2 )
      assert_include( "lat_rd:[1.2 TO 1.7]", result)
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 0
    end

    should "reverse the range and work as ususal" do
      result = range_query( "lat" , 10.7 , 1.2 )
      assert_include( "lat_rd:[1.2 TO 2]", result)
      assert_include( "lat_ri:[2 TO 9]", result)
      assert_include( "lat_rd:[10 TO 10.7]", result)
      assert result.scan(/lat_/).size == 3
      assert result.scan(/ OR /).size == 2
    end
    
    should "work with open end range" do
      result = range_query( "lat" , 10.7 , "*" )
      assert_include( "lat_rd:[10.7 TO 11]", result)
      assert_include( "lat_ri:[11 TO *]", result)
      assert result.scan(/lat_/).size == 2
      assert result.scan(/ OR /).size == 1
    end

    should "work with open start range" do
      result = range_query( "lat" , "*", 10.7 )
      assert_include( "lat_ri:[* TO 9]", result)
      assert_include( "lat_rd:[10 TO 10.7]", result)
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 1
    end
    
    context "sliced N times" do
      setup do
        stubs(:configuration).returns( {:solr_fields => { :lat => 
                { :type => :range_double, :sliced => [4,10] } } } )
      end
        
      should "query usual range" do
        result = range_query( "lat" , "1.123456789012345" , "10.345678123456789012345" )
        assert_include( "lat_rd:[1.123456789012345 TO 1.1234567891]", result)
        assert_include( "lat_10d_rd:[1.1234567891 TO 1.1234999999]", result)
        assert_include( "lat_4d_rd:[1.1235 TO 1.9999]", result)
        assert_include( "lat_ri:[2 TO 9]", result)
        assert_include( /lat_4d_rd\:\[10(\.0+)? TO 10\.3455\]/, result)
        assert_include( /lat_10d_rd\:\[10\.3456(0+)? TO 10\.3456781233\]/, result)
        assert_include( "lat_rd:[10.3456781234 TO 10.345678123456789012345]", result)
        assert result.scan(/lat_/).size == 7
        assert result.scan(/ OR /).size == 6
      end
      
      should "query starts with int and end is not enough precise" do
        result = range_query( "lat" , 1.0 , 10.3 )
        assert_include( "lat_ri:[1 TO 9]", result)
        assert_include( /lat_4d_rd\:\[10(\.0+)? TO 10\.2999\]/, result)
        assert_include( "lat_rd:[10.3 TO 10.3]", result)
        assert result.scan(/lat_/).size == 3
        assert result.scan(/ OR /).size == 2
      end
      
      should "query ends with int" do
        result = range_query( "lat" , 1.8 , 10 )
        #Don't use lat_rd at start 'cause the start does not have more than 4 decimals
        assert_include( "lat_4d_rd:[1.8 TO 1.9999]", result) #gets from 1.80 to 2.000099999...
        assert_include( "lat_ri:[2 TO 9]", result) # gets from 3.0 to 9.9999...
         # a Needed strange range to include the value 10
        assert_include( "lat_rd:[10.0 TO 10.0]", result)
        assert result.scan(/lat_/).size == 3, result
        assert result.scan(/ OR /).size == 2, result
      end
      
      should "query no range" do
        result = range_query( "lat" , 1.8 , 1.8 )
        assert_include( "lat_rd:[1.8 TO 1.8]", result)
        assert result.scan(/lat_rd/).size == 1
        assert result.scan(/ OR /).size == 0
      end
  
      should "query no int part used" do
        result = range_query( "lat" , 1.8 , 1.9 )
        assert_include( "lat_4d_rd:[1.8 TO 1.8999]", result)
        assert_include( "lat_rd:[1.9 TO 1.9]", result)
        assert result.scan(/lat_/).size == 2
        assert result.scan(/ OR /).size == 1
      end
  
      should "query reverse range is reverted" do
        result = range_query( "lat" , 1.7 , 1.2 )
        assert_include( "lat_4d_rd:[1.2 TO 1.6999]", result)
        assert_include( "lat_rd:[1.7 TO 1.7]", result)
        assert result.scan(/lat_/).size == 2
        assert result.scan(/ OR /).size == 1
      end
  
      should "reverse the range and work as ususal" do
        result = range_query( "lat" , 10.7 , 1.2 )
        assert_include( "lat_4d_rd:[1.2 TO 1.9999]", result)
        assert_include( "lat_ri:[2 TO 9]", result)
        assert_include( /lat_4d_rd\:\[10(\.0+)? TO 10\.6999\]/, result)
        assert_include( "lat_rd:[10.7 TO 10.7]", result)
        assert result.scan(/lat_/).size == 4
        assert result.scan(/ OR /).size == 3
      end
      
      should "work with open end range" do
        result = range_query( "lat" , 10.7 , "*" )
        assert_include( "lat_4d_rd:[10.7 TO 10.9999]", result)
        assert_include( "lat_ri:[11 TO *]", result)
        assert result.scan(/lat_/).size == 2, result
        assert result.scan(/ OR /).size == 1, result
      end

      should "work with open start range" do
        result = range_query( "lat" , "*", 10.7 )
        assert_include("lat_ri:[* TO 9]", result)
        assert_include( /lat_4d_rd\:\[10(.0+)? TO 10\.6999\]/, result)
        assert_include( "lat_rd:[10.7 TO 10.7]", result)
        assert result.scan(/lat_/).size == 3
        assert result.scan(/ OR /).size == 2
      end

      should "work with open end range long" do
        result = range_query( "lat" , "10.712345678901" , "*" )
        assert_include( "lat_rd:[10.712345678901 TO 10.712345679]", result)
        assert_include( "lat_10d_rd:[10.712345679 TO 10.7123999999]", result)
        assert_include( "lat_4d_rd:[10.7124 TO 10.9999]", result)
        assert_include( "lat_ri:[11 TO *]", result)
        assert result.scan(/lat_/).size == 4, result
        assert result.scan(/ OR /).size == 3, result
      end

      should "work with open start range long" do
        result = range_query( "lat" , "*", "10.712345678901" )
        assert_include("lat_ri:[* TO 9]", result)
        assert_include( /lat_4d_rd\:\[10(.0+)? TO 10\.7122\]/, result)
        assert_include( /lat_10d_rd\:\[10\.7123 TO 10\.7123456788\]/, result)
        assert_include( "lat_rd:[10.7123456789 TO 10.712345678901]", result)
        assert result.scan(/lat_/).size == 4
        assert result.scan(/ OR /).size == 3
      end

      should "only 10 decimals part used and full field" do
        result = range_query( "lat", "1.12345678", "1.12345679")
        assert_include( /lat_10d_rd\:\[1\.12345678 TO 1\.1234567899\]/, result)
        assert_include( /lat_rd\:\[1\.12345679 TO 1\.12345679\]/, result)
      end

      should " allow diferent float depths " do
        result = range_query( "lat", "1.12345678", "1.1234567912345")
        assert_include( /lat_10d_rd\:\[1\.12345678 TO 1\.1234567911\]/, result)
        assert_include( /lat_rd\:\[1\.1234567912 TO 1\.1234567912345\]/, result)
      end
      
      should " ask for value from 5 to 24 " do
        result = range_query( "lat", 5.0, 24.0 )
        assert_include( /lat_ri\:\[5 TO 23\]/, result )
        assert_include( /lat_rd\:\[24(.0+)? TO 24(.0+)?\]/, result )
      end
      
    end
    
    context "sliced twice" do
      setup do
        stubs(:configuration).returns( {:solr_fields => { :lat => { :type => :range_double, :sliced => 2 } } } )
      end

      should "query usual range" do
        result = range_query( "lat" , 1.123456 , 10.345678 )
        assert_include( "lat_rd:[1.123456 TO 1.1235]", result) # 1.123456 to 123500...
        assert_include( "lat_4d_rd:[1.1235 TO 1.9999]", result) # gets 1.1235000 to 2.000099...
        assert_include( "lat_ri:[2 TO 9]", result) #gets 2.000... to 9.99999
        assert_include( /lat_4d_rd\:\[10(\.0+)? TO 10\.3455\]/, result) # gets 10.000... to 10.3455999..
        assert_include( "lat_rd:[10.3456 TO 10.345678]", result)
        assert result.scan(/lat_/).size == 5
        assert result.scan(/ OR /).size == 4
      end

      should "query starts with int and end is not enough precise" do
        result = range_query( "lat" , 1.0 , 10.3 )
        assert_include( "lat_ri:[1 TO 9]", result)
        assert_include( /lat_4d_rd\:\[10(\.0+)? TO 10\.2999\]/, result)
        assert_include( "lat_rd:[10.3 TO 10.3]", result)
        assert result.scan(/lat_/).size == 3
        assert result.scan(/ OR /).size == 2
      end

      should "query ends with int" do
        result = range_query( "lat" , 1.8 , 10 )
        #Don't use lat_rd at start 'cause the start does not have more than 4 decimals
        assert_include( "lat_4d_rd:[1.8 TO 1.9999]", result) #gets from 1.80 to 2.000099999...
        assert_include( "lat_ri:[2 TO 9]", result) # gets from 3.0 to 9.9999...
         # a Needed strange range to include the value 10
        assert_include( "lat_rd:[10.0 TO 10.0]", result)
        assert result.scan(/lat_/).size == 3, result
        assert result.scan(/ OR /).size == 2, result
      end

      should "query no range" do
        result = range_query( "lat" , 1.8 , 1.8 )
        assert_include( "lat_rd:[1.8 TO 1.8]", result)
        assert result.scan(/lat_rd/).size == 1
        assert result.scan(/ OR /).size == 0
      end

      should "query no int part used" do
        result = range_query( "lat" , 1.8 , 1.9 )
        assert_include( "lat_4d_rd:[1.8 TO 1.8999]", result)
        assert_include( "lat_rd:[1.9 TO 1.9]", result)
        assert result.scan(/lat_/).size == 2
        assert result.scan(/ OR /).size == 1
      end

      should "query reverse range is reverted" do
        result = range_query( "lat" , 1.7 , 1.2 )
        assert_include( "lat_4d_rd:[1.2 TO 1.6999]", result)
        assert_include( "lat_rd:[1.7 TO 1.7]", result)
        assert result.scan(/lat_/).size == 2
        assert result.scan(/ OR /).size == 1
      end

      should "reverse the range and work as ususal" do
        result = range_query( "lat" , 10.7 , 1.2 )
        assert_include( "lat_4d_rd:[1.2 TO 1.9999]", result)
        assert_include( "lat_ri:[2 TO 9]", result)
        assert_include( /lat_4d_rd\:\[10(\.0+)? TO 10\.6999\]/, result)
        assert_include( "lat_rd:[10.7 TO 10.7]", result)
        assert result.scan(/lat_/).size == 4
        assert result.scan(/ OR /).size == 3
      end

      should "work with open end range" do
        result = range_query( "lat" , 10.7 , "*" )
        assert_include( "lat_4d_rd:[10.7 TO 10.9999]", result)
        assert_include( "lat_ri:[11 TO *]", result)
        assert result.scan(/lat_/).size == 2, result
        assert result.scan(/ OR /).size == 1, result
      end

      should "work with open start range" do
        result = range_query( "lat" , "*", 10.7 )
        assert_include("lat_ri:[* TO 9]", result)
        assert_include( /lat_4d_rd\:\[10(.0+)? TO 10\.6999\]/, result)
        assert_include( "lat_rd:[10.7 TO 10.7]", result)
        assert result.scan(/lat_/).size == 3
        assert result.scan(/ OR /).size == 2
      end
    end

  end
  
end