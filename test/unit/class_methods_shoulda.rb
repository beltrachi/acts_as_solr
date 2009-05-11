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
  
  def solr_configuration
    @solr_configuration ||= {:type_field => "type_t", :primary_key_field => "id"}
  end
  
  context "when multi-searching" do
    setup do
      stubs(:name).returns("User")
    end
    
    should "include the type field in the query" do
      expects(:parse_query).with("name:paul", {:results_format => :objects}, "AND (type_t:User)")
      multi_solr_search("name:paul")
    end
    
    should "add all models in the query" do
      expects(:parse_query).with("name:paul", {:results_format => :objects, :models => ["Movie", "DVD"]}, "AND (type_t:User OR type_t:Movie OR type_t:DVD)")
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
      assert result.include?("[2009-01-01T12:00:00Z TO 2009-01-02T00:00:00Z]")
      assert result.include?("created_at_day_d:[2009-01-02T00:00:00Z TO 2009-01-12T00:00:00Z]")
      assert result.include?("[2009-01-12T00:00:00Z TO 2009-01-12T12:00:00Z]")
    end

    should "not include the first part if its empty" do
      result = range_query( "created_at" , Time.parse("2009-01-02T00:00:00Z"), Time.parse("2009-01-12T12:00:00Z") )
      assert !result.include?("[2009-01-02T00:00:00Z TO 2009-01-02T00:00:00Z]")
      assert result.include?("created_at_day_d:[2009-01-02T00:00:00Z TO 2009-01-12T00:00:00Z]")
      assert result.include?("[2009-01-12T00:00:00Z TO 2009-01-12T12:00:00Z]")
      assert result.scan(/created_at/).size == 2
    end

    should "not include the last part if its empty" do
      result = range_query( "created_at" , Time.parse("2009-01-01T12:00:00Z"), Time.parse("2009-01-12T00:00:00Z") )
      assert result.include?("[2009-01-01T12:00:00Z TO 2009-01-02T00:00:00Z]")
      assert result.include?("created_at_day_d:[2009-01-02T00:00:00Z TO 2009-01-12T00:00:00Z]")
      assert !result.include?("[2009-01-12T00:00:00Z TO 2009-01-12T12:00:00Z]")
      assert result.scan(/created_at/).size == 2
    end

    should "not include the first and the last part if its empty" do
      result = range_query( "created_at" , Time.parse("2009-01-01T00:00:00Z"), Time.parse("2009-01-12T00:00:00Z") )
      assert !result.include?("[2009-01-01T00:00:00Z TO 2009-01-01T00:00:00Z]")
      assert result.include?("created_at_day_d:[2009-01-01T00:00:00Z TO 2009-01-12T00:00:00Z]")
      assert !result.include?("[2009-01-12T00:00:00Z TO 2009-01-12T00:00:00Z]")
      assert result.scan(/created_at/).size == 1
    end

    should "not do the dayquery when the range is lower than a whole day" do
      result = range_query( "created_at" , Time.parse("2009-01-01T12:00:00Z"), Time.parse("2009-01-01T13:00:00Z") )
      assert result.include?("[2009-01-01T12:00:00Z TO 2009-01-01T13:00:00Z]")
      assert !result.include?("created_at_day")
      assert result.scan(/created_at/).size == 1
    end

    should "not include the day query when its not needed" do
      result = range_query( "created_at" , Time.parse("2009-01-01T12:00:00Z"), Time.parse("2009-01-02T13:00:00Z") )
      assert !result.include?("created_at_day_d")
      assert result.include?("[2009-01-01T12:00:00Z TO 2009-01-02T00:00:00Z]")
      assert result.include?("[2009-01-02T00:00:00Z TO 2009-01-02T13:00:00Z]")
      assert result.scan(/created_at/).size == 2
    end

    context "on open ranges" do
      should " open end " do
        result = range_query( "created_at" , Time.parse("2009-01-01T12:00:00Z"), "*" )
        assert result.include?("[2009-01-01T12:00:00Z TO 2009-01-02T00:00:00Z]")
        assert result.include?("[2009-01-02T00:00:00Z TO *]")
        assert result.scan(/created_at/).size == 2
      end

      should " open start " do
        result = range_query( "created_at" , "*", Time.parse("2009-01-01T12:00:00Z") )
        assert result.include?("[2009-01-01T00:00:00Z TO 2009-01-01T12:00:00Z]")
        assert result.include?("created_at_day_d:[* TO 2009-01-01T00:00:00Z]")
        assert result.scan(/created_at/).size == 2
      end

      should " open start day sharp" do
        result = range_query( "created_at" , "*", Time.parse("2009-01-01T00:00:00Z") )
        assert result.include?("created_at_day_d:[* TO 2009-01-01T00:00:00Z]")
        assert result.scan(/created_at/).size == 1
      end

      should " open end day sharp" do
        result = range_query( "created_at" , Time.parse("2009-01-01T00:00:00Z"), "*" )
        assert result.include?("created_at_day_d:[2009-01-01T00:00:00Z TO *]")
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
      assert result.include?("lat_rd:[1.1 TO 2]")
      assert result.include?("lat_ri:[2 TO 10]")
      assert result.include?("lat_rd:[10 TO 10.3]")
      assert result.scan(/lat_rd/).size == 2
      assert result.scan(/ OR /).size == 2
    end
    
    should "query starts with int" do
      result = range_query( "lat" , 1.0 , 10.3 )
      assert result.include?("lat_ri:[1 TO 10]")
      assert result.include?("lat_rd:[10 TO 10.3]")
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 1
    end
    
    should "query ends with int" do
      result = range_query( "lat" , 1.8 , 10 )
      assert result.include?("lat_rd:[1.8 TO 2]")
      assert result.include?("lat_ri:[2 TO 10]")
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 1
    end
    
    should "query no range" do
      result = range_query( "lat" , 1.8 , 1.8 )
      assert result.include?("lat_rd:[1.8 TO 1.8]")
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 0
    end

    should "query no int part used" do
      result = range_query( "lat" , 1.8 , 1.9 )
      assert result.include?("lat_rd:[1.8 TO 1.9]")
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 0
    end

    should "query reverse range is reverted" do
      result = range_query( "lat" , 1.7 , 1.2 )
      assert result.include?("lat_rd:[1.2 TO 1.7]")
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 0
    end

    should "reverse the range and work as ususal" do
      result = range_query( "lat" , 10.7 , 1.2 )
      assert result.include?("lat_rd:[1.2 TO 2]")
      assert result.include?("lat_rd:[10 TO 10.7]")
      assert result.include?("lat_ri:[2 TO 10]")
      assert result.scan(/lat_rd/).size == 2
      assert result.scan(/ OR /).size == 2
    end
    
    should "work with open end range" do
      result = range_query( "lat" , 10.7 , "*" )
      assert result.include?("lat_rd:[10.7 TO 11]")
      assert result.include?("lat_ri:[11 TO *]")
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 1
    end

    should "work with open start range" do
      result = range_query( "lat" , "*", 10.7 )
      assert result.include?("lat_ri:[* TO 10]")
      assert result.include?("lat_rd:[10 TO 10.7]")
      assert result.scan(/lat_rd/).size == 1
      assert result.scan(/ OR /).size == 1
    end
    
    
  end
  
end