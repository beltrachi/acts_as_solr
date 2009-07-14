# encoding: utf-8
require "#{File.dirname(File.expand_path(__FILE__))}/../test_helper"

class SlicedTest < Test::Unit::TestCase
  
  fixtures :authors, :photos, :categories

  # Inserting new data into Solr and making sure it's getting indexed
  def test_insert_new_data_and_destroy
    assert_equal 4, Photo.count_by_solr('author_id:1 OR author_id:2')
    ph = Photo.create(
      :name => "Middlepoint", 
      :author_id => 1, 
      :category_id => 1,
      :taken_on => 3.days.ago,
      :lat => 15.0,
      :lng => 15.0
      )
    assert ph.valid?
    doc = ph.to_solr_doc.to_xml.to_s
    [ 'author_name', 'category_name'].each do |f|
      assert doc.include?( f )
      assert doc.include?( f + "_facet") 
    end

    assert_equal 5, Photo.count_by_solr('author_id:1 OR author_id:2')
    ph.destroy
    assert_equal 4, Photo.count_by_solr('author_id:1 OR author_id:2')
  end
  
  def test_basic_search_on_sliced_fields
    photos = Photo.find_by_solr( Photo.range_query( 'lat', 5.0, 14.0 ) )
    assert_equal 2, photos.total
    ids = photos.docs.collect( &:id )
    assert ids.include?( 1 )
    assert ids.include?( 2 )
    
    #date search
    photos = Photo.find_by_solr( 
      Photo.range_query( 'taken_on', 4.days.ago, Time.now ) )
    assert_equal 4, photos.total
    ids = photos.docs.collect( &:id )
    [ 1,2,3,4 ].each do |id|
      assert ids.include?( id )
    end
  end
  
  def test_search_sliced_and_faceted
    opt = { :facets => { :fields =>[:author_name], :mincount => 1 } }
    queries = [ Photo.range_query( 'lat', 4.0, 24.0 ) ]
    photos = Photo.find_by_solr( queries.join( " AND " ), opt )
    assert_equal Photo.count, photos.docs.size

    queries =  [ Photo.range_query( 'lat', 5.0, 14.0 ) ]
    queries << ' author_name:"Tom Clancy" '
    
    photos = Photo.find_by_solr( queries.join( " AND " ), opt )
    
    assert_equal photos.total, 1
    assert_equal photos.facets["facet_fields"]["author_name_facet"].size, 1
    
  end
  
  def test_precise_float_by_range
    p = Photo.find(1)
    v = 10.123456789
    p.lat = v
    p.save!
    assert_equal v, p.lat
    photos = Photo.find_by_solr( Photo.range_query( 'lat', 10.123, 10.123456789 ) )
    assert_equal [ p ], photos.docs
  end
end
