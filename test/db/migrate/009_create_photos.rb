class CreatePhotos < ActiveRecord::Migration
  def self.up
    create_table :photos, :force => true do |t|
      t.column :category_id, :integer
      t.column :name, :string
      t.column :author_id, :integer
      t.column :file, :string
      t.column :taken_on, :datetime
      t.column :lat, :decimal, :precision => 18, :scale => 15
      t.column :lng, :decimal, :precision => 18, :scale => 15 
    end
  end

  def self.down
    drop_table :photos
  end
end
