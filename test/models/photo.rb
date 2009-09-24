# Table fields for 'photos'
# - id
# - name
# - description

class Photo < ActiveRecord::Base

  belongs_to :author
  belongs_to :category
  has_and_belongs_to_many :tags
  
  instance_fields_indexed = self.new.attributes.keys.map( &:to_sym ).select do |f|
    ![ :lat, :lng, :taken_at ].include?( f )
  end
  lat_lng_field = { :type => :range_double, :sliced => [4,10] }
  instance_fields_indexed << { :lat => lat_lng_field }
  instance_fields_indexed << { :lng => lat_lng_field }
  instance_fields_indexed << { :taken_on => { :type => :date, :sliced => 1 } }
  
  acts_as_solr( :fields => instance_fields_indexed,
    :facets => [:author_name, :category_name, :tag_name ],
    :include => [
      {:author => {:using => :name, :as => :author_name }},
      {:category => { :using => :name, :as => :category_name }},
      {:tags => { :using => :name, :as => :tag_name, :multivalued=> true } }
    ])
  
end